// What lies on a face's boundary: its singular points, and whether the
// edges traced on it end on an edge of the face, at a singular point, or at
// another end.
#include "contours.hxx"

namespace huak::space {
std::vector<TopoDS_Vertex> singularPoints(const TopoDS_Face &face) {
  std::vector<TopoDS_Vertex> points;
  for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
    const auto &edge = TopoDS::Edge(e.Current());
    if (!BRep_Tool::Degenerated(edge))
      continue;
    const auto v = TopExp::FirstVertex(edge);
    if (!v.IsNull() && std::none_of(points.begin(), points.end(),
                                    [&](const auto &p) { return p.IsSame(v); }))
      points.push_back(v);
  }
  return points;
}
} // namespace huak::space

namespace huak::space::contour {
// The face's singular points, each with its degenerated edge's curve on
// the face.
std::vector<Singular> singularArcs(const TopoDS_Face &face) {
  std::vector<Singular> found;
  for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
    const auto &edge = TopoDS::Edge(e.Current());
    if (!BRep_Tool::Degenerated(edge))
      continue;
    const auto v = TopExp::FirstVertex(edge);
    double first, last;
    const auto arc = BRep_Tool::CurveOnSurface(edge, face, first, last);
    if (!v.IsNull() && !arc.IsNull())
      found.push_back({BRep_Tool::Pnt(v), BRep_Tool::Tolerance(v), arc, first, last});
  }
  return found;
}

namespace {
// Whether a point lies on an edge of the face other than a seam, where the
// face meets itself, or a degenerated edge, within `within` and the edge's
// tolerance.
bool onBoundary(const TopoDS_Face &face, const gp_Pnt &p, double within) {
  for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
    const auto &edge = TopoDS::Edge(e.Current());
    if (BRep_Tool::Degenerated(edge) || BRep_Tool::IsClosed(edge, face))
      continue;
    double a, b;
    const auto curve = BRep_Tool::Curve(edge, a, b);
    if (curve.IsNull())
      continue;
    const double reach = within + BRep_Tool::Tolerance(edge);
    if (curve->Value(a).Distance(p) <= reach || curve->Value(b).Distance(p) <= reach)
      return true;
    GeomAPI_ProjectPointOnCurve onto(p, curve, a, b);
    if (onto.NbPoints() && onto.LowerDistance() <= reach)
      return true;
  }
  return false;
}

// An end of an edge that stands open: on no edge of the face but a seam, at
// no singular point, and at no other end, which is the edge's own other end
// where the edge closes.
struct OpenEnd {
  size_t edge;
  bool last;
  TopoDS_Vertex vertex;
};
std::vector<OpenEnd> openEnds(const TopoDS_Face &face, const std::vector<TopoDS_Edge> &edges) {
  const auto singular = singularPoints(face);
  std::vector<TopoDS_Vertex> ends;
  for (const auto &edge : edges) {
    TopoDS_Vertex a, b;
    TopExp::Vertices(edge, a, b);
    ends.push_back(a);
    ends.push_back(b);
  }
  std::vector<OpenEnd> open;
  for (size_t i = 0; i < ends.size(); ++i) {
    const auto &v = ends[i];
    if (v.IsNull())
      continue;
    const gp_Pnt p = BRep_Tool::Pnt(v);
    const double reach = BRep_Tool::Tolerance(v);
    if (onBoundary(face, p, reach))
      continue;
    if (std::any_of(singular.begin(), singular.end(), [&](const TopoDS_Vertex &s) {
          return BRep_Tool::Pnt(s).Distance(p) <= BRep_Tool::Tolerance(s) + reach;
        }))
      continue;
    bool met = false;
    for (size_t j = 0; j < ends.size() && !met; ++j)
      met = j != i && !ends[j].IsNull() &&
            (ends[j].IsSame(v) ||
             BRep_Tool::Pnt(ends[j]).Distance(p) <= BRep_Tool::Tolerance(ends[j]) + reach);
    if (!met)
      open.push_back({i / 2, i % 2 == 1, v});
  }
  return open;
}
} // namespace

// Every end of an edge lies on an edge of the face, at a singular point, or
// at another end.
void requireClosedEnds(const TopoDS_Face &face, const std::vector<TopoDS_Edge> &edges) {
  const auto open = openEnds(face, edges);
  if (open.empty())
    return;
  throw std::runtime_error("OCCT left a contour open inside its face");
}
} // namespace huak::space::contour
