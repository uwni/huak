// Contours of a face: where its normal makes a constant angle with a
// direction, or where a line of sight from an eye grazes it. They are
// marched on a grid of the face's parameters, OCCT's contour function
// placing their points; each traced piece becomes an edge on the face,
// fitted to points on the contour.
#include "contours.hxx"

namespace huak::space {
namespace {
// The part of a part of the grid by which its inner nodes are shifted off
// the even fractions of the face's parameters: the golden section's, less
// a half. A contour that runs along a line of nodes, or crosses itself at
// one, leaves the nodes on it no sign of its own; the symmetric views and
// lights of faces of revolution and of quadrics put their contours along
// the quarters and eighths of the parameters, which the shifted nodes
// never meet.
const double shift = (std::sqrt(5.0) - 1) / 2 - 0.5;

// The contours of a face, marched on a grid of the face's parameters. The
// grid starts at eight parts each way, its inner nodes shifted by `shift`,
// and halves each part across which the normal turns more than `limit`
// between neighbouring nodes, down to what OCCT tells apart. Where tracing
// on it finds a piece of the contour crossing a line of the grid between
// two nodes and back, the grid's cell there is halved both ways and the
// contours traced again. Contours along an edge of the face are that edge.
Contours march(TopoDS_Face face, const contour::ContourFunction &function, double limit) {
  face.Orientation(TopAbs_FORWARD);
  const Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
  contour::OnContour onContour(function);
  Contours result;
  double u0, u1, v0, v1;
  BRepTools::UVBounds(face, u0, u1, v0, v1);
  std::vector<double> us{u0}, vs{v0};
  for (int k = 1; k < 8; ++k) {
    us.push_back(u0 + (u1 - u0) * (k + shift) / 8);
    vs.push_back(v0 + (v1 - v0) * (k + shift) / 8);
  }
  us.push_back(u1);
  vs.push_back(v1);
  // Halves the parts of a row of the grid's lines marked to split.
  const auto refine = [](std::vector<double> &at, const std::vector<bool> &split) {
    std::vector<double> finer{at.front()};
    for (size_t k = 0; k + 1 < at.size(); ++k) {
      if (split[k])
        finer.push_back((at[k] + at[k + 1]) / 2);
      finer.push_back(at[k + 1]);
    }
    at = std::move(finer);
  };
  // The grid's normals, row by row; none where the surface tells none.
  std::vector<std::optional<gp_Dir>> normals;
  const auto index = [&](size_t i, size_t j) { return i * vs.size() + j; };
  for (;;) {
    normals.assign(us.size() * vs.size(), std::nullopt);
    for (size_t i = 0; i < us.size(); ++i)
      for (size_t j = 0; j < vs.size(); ++j) {
        gp_Dir n;
        if (GeomLib::NormEstim(surface, gp_Pnt2d(us[i], vs[j]), Precision::Confusion(), n) < 2)
          normals[index(i, j)] = n;
      }
    const auto turns = [&](size_t a, size_t b) {
      return normals[a] && normals[b] && normals[a]->Angle(*normals[b]) > limit;
    };
    std::vector<bool> splitU(us.size() - 1, false), splitV(vs.size() - 1, false);
    bool any = false;
    for (size_t i = 0; i < us.size(); ++i)
      for (size_t j = 0; j < vs.size(); ++j) {
        if (i + 1 < us.size() && us[i + 1] - us[i] > Precision::PConfusion() && turns(index(i, j), index(i + 1, j)))
          any = splitU[i] = true;
        if (j + 1 < vs.size() && vs[j + 1] - vs[j] > Precision::PConfusion() && turns(index(i, j), index(i, j + 1)))
          any = splitV[j] = true;
      }
    if (!any)
      break;
    refine(us, splitU);
    refine(vs, splitV);
  }
  // The contour along an edge of the face is that edge, as the function
  // tells to first order at its ends, its middle and its quarters, where it
  // tells anything: where OCCT's normal has no length, as where the edge
  // meets a singular point, it tells nothing.
  for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
    const auto &edge = TopoDS::Edge(e.Current());
    if (BRep_Tool::Degenerated(edge))
      continue;
    double first, last;
    const auto arc = BRep_Tool::CurveOnSurface(edge, face, first, last);
    if (arc.IsNull())
      continue;
    const double within = BRep_Tool::Tolerance(edge) + Precision::Confusion();
    bool runs = true;
    for (int k = 0; k <= 4 && runs; ++k) {
      const gp_Pnt2d uv = arc->Value(first + (last - first) * k / 4);
      if (!onContour.tells(uv))
        continue;
      gp_Pnt p;
      gp_Vec du, dv;
      surface->D1(uv.X(), uv.Y(), p, du, dv);
      runs = onContour.away(uv) * contour::stretch(du, dv) <= within;
    }
    if (runs && std::none_of(result.along.begin(), result.along.end(), [&](const TopoDS_Edge &other) { return other.IsSame(edge); }))
      result.along.push_back(edge);
  }
  for (;;) {
    try {
      result.curves = contour::GridTrace(face, function, us, vs, result.along).edges();
      return result;
    } catch (const contour::Unresolved &cell) {
      std::vector<bool> splitU(us.size() - 1, false), splitV(vs.size() - 1, false);
      splitU[cell.i] = us[cell.i + 1] - us[cell.i] > Precision::PConfusion();
      splitV[cell.j] = vs[cell.j + 1] - vs[cell.j] > Precision::PConfusion();
      refine(us, splitU);
      refine(vs, splitV);
    }
  }
}

} // namespace

std::vector<TopoDS_Edge> traceContours(TopoDS_Face face, gp_Dir direction, double angle) {
  // OCCT's contour function measures the angle from the surface's own
  // normal, which a reversed face turns around. The loop of this angle
  // about where the normal is the direction has that radius, or its
  // supplement, in the normal's turning; a grid turning half as much
  // between nodes holds a node inside it.
  if (face.Orientation() == TopAbs_REVERSED)
    direction.Reverse();
  contour::ContourFunction function(new BRepAdaptor_Surface(face));
  function.Set(direction, angle - M_PI / 2);
  return march(face, function, std::min(angle, M_PI - angle) / 2).curves;
}

Contours traceOutlines(const TopoDS_Face &face, const HLRAlgo_Projector &projector) {
  // As hidden-line removal sets it up: toward the viewer, or from the eye;
  // where the normal is square to it, at the radius of a right angle from
  // where the normal points that way.
  gp_Vec toward(0, 0, 1);
  toward.Transform(projector.InvertedTransformation());
  contour::ContourFunction function(new BRepAdaptor_Surface(face));
  if (projector.Perspective())
    function.Set(gp_Pnt(projector.Focus() * toward.XYZ()));
  else
    function.Set(gp_Dir(toward));
  return march(face, function, M_PI / 4);
}
} // namespace huak::space
