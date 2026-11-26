// Tracing the paths on the grid: where they leave the face and where they
// are cut, and the edges fitted to the pieces between.
#include "contours.hxx"

namespace huak::space::contour {
namespace {
// OCCT's contour function along a curve on the face.
class Along : public math_Function {
public:
  Along(const Adaptor2d_Curve2d &arc, const ContourFunction &function) : arc(arc), function(function) {}
  bool Value(double s, double &f) override {
    f = at(s).value;
    return true;
  }
  // Whether the function vanishes at `s` as far as rounding tells.
  bool vanishes(double s) const {
    const auto reading = at(s);
    return std::abs(reading.value) <= reading.rounding;
  }

private:
  ContourFunction::Reading at(double s) const {
    const gp_Pnt2d uv = arc.Value(s);
    return function.value(uv.X(), uv.Y());
  }

  const Adaptor2d_Curve2d &arc;
  const ContourFunction &function;
};

// The root of the contour function along a curve on the face nearest its
// parameter `at`, between `first` and `last`: where the function changes
// sign, as OCCT's root finder finds it, or vanishes as far as rounding
// tells, as Adams's criterion accepts a root (OnContour). None where it
// keeps its sign.
std::optional<double> rootAlong(Along &along, double at, double first, double last) {
  double here;
  if (!along.Value(at, here))
    return std::nullopt;
  if (here == 0 || along.vanishes(at))
    return at;
  for (double h = 1e-9 * (last - first); h <= 2 * (last - first); h *= 2)
    for (const double s : {std::max(first, at - h), std::min(last, at + h)}) {
      double there;
      if (!along.Value(s, there))
        continue;
      if (here * there > 0) {
        if ((s == first || s == last) && along.vanishes(s))
          return s;
        continue;
      }
      math_BracketedRoot root(along, std::min(at, s), std::max(at, s), 1e-3 * Precision::PConfusion());
      if (root.IsDone())
        return root.Root();
      return std::nullopt;
    }
  return std::nullopt;
}
} // namespace

// Where a path between two of its points leaves the face: the root of
// the function along the edge whose curve on the face the chord between
// them crosses, nearest where it does.
std::optional<Sample> GridTrace::leaving(const gp_Pnt2d &in, const gp_Pnt2d &out) {
  if (in.Distance(out) <= gp::Resolution())
    return std::nullopt;
  const Handle(Geom2d_Curve) chord = new Geom2d_TrimmedCurve(new Geom2d_Line(in, gp_Dir2d(gp_Vec2d(in, out))), 0, in.Distance(out));
  for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
    const auto &edge = TopoDS::Edge(e.Current());
    double first, last;
    const auto arc = BRep_Tool::CurveOnSurface(edge, face, first, last);
    if (arc.IsNull())
      continue;
    Geom2dAPI_InterCurveCurve meets(new Geom2d_TrimmedCurve(arc, first, last), chord, Precision::PConfusion());
    if (meets.NbPoints() == 0)
      continue;
    double s;
    {
      Geom2dAPI_ProjectPointOnCurve onto(meets.Point(1), arc, first, last);
      s = onto.NbPoints() ? onto.LowerDistanceParameter() : first;
    }
    const Geom2dAdaptor_Curve adapted(arc, first, last);
    Along along(adapted, function);
    if (const auto root = rootAlong(along, s, first, last)) {
      const gp_Pnt2d uv = arc->Value(*root);
      return Sample{uv, surface->Value(uv.X(), uv.Y()), true, true};
    }
  }
  return std::nullopt;
}

const Singular *GridTrace::singularAt(const gp_Pnt &p) const {
  for (const auto &s : singular)
    if (s.at.Distance(p) <= s.reach + Precision::Confusion())
      return &s;
  return nullptr;
}

// Whether a point lies on an edge of the face: on its boundary in the
// face's parameters, as OCCT's classifier finds it; at a singular point,
// all of whose degenerated edge stands for the point; or, within the
// edge's tolerance, on an edge that the contour runs along.
bool GridTrace::onAlong(const gp_Pnt &p) const {
  return std::any_of(along.begin(), along.end(),
                     [&](const TopoDS_Edge &edge) { return pointOnEdge(edge, p, Precision::Confusion()); });
}

bool GridTrace::onEdge(const gp_Pnt2d &uv, TopAbs_State state) const {
  const gp_Pnt p = surface->Value(uv.X(), uv.Y());
  return state == TopAbs_ON || singularAt(p) || onAlong(p);
}

// Samples the contour evenly along a traced piece, as many spans as the
// piece has, and fits an edge to the samples, closing where `closed`. A
// piece between two points on edges of the face whose middle on the
// contour lies on an edge too runs along them, and is theirs.
void GridTrace::trace(Piece piece, bool closed) {
  auto &points = piece.points;
  points.front().along = 0;
  for (size_t k = 1; k < points.size(); ++k)
    points[k].along = points[k - 1].along + points[k - 1].p.Distance(points[k].p);
  const auto locate = [&](double along) {
    const auto next = std::upper_bound(points.begin() + 1, points.end() - 1, along,
                                       [](double at, const Sample &s) { return at < s.along; });
    const size_t k = static_cast<size_t>(next - points.begin()) - 1;
    const Sample &a = points[k], &b = points[k + 1];
    if (along <= a.along)
      return a;
    if (along >= b.along)
      return b;
    const double s = (along - a.along) / (b.along - a.along);
    const gp_Pnt2d uv = onLink(links[piece.through[k]],
                               gp_Pnt2d(a.uv.X() + s * (b.uv.X() - a.uv.X()), a.uv.Y() + s * (b.uv.Y() - a.uv.Y())));
    Sample found{uv, surface->Value(uv.X(), uv.Y())};
    found.along = along;
    return found;
  };
  const double length = points.back().along;
  if (points.size() == 2 && points.front().edge && points.back().edge) {
    const gp_Pnt2d middle = locate(length / 2).uv;
    if (onEdge(middle, classifier.Perform(middle)))
      return;
  }
  const size_t spans = points.size() - 1;
  std::vector<Sample> samples{points.front()};
  for (size_t k = 1; k < spans; ++k)
    samples.push_back(locate(length * static_cast<double>(k) / static_cast<double>(spans)));
  samples.push_back(points.back());
  for (auto &sample : samples)
    sample.singular = singularAt(sample.p);
  const TopoDS_Vertex start = built.vertexAt(points.front().p), end = closed ? start : built.vertexAt(points.back().p);
  // A contour that a line or a circle stands for, as it is measured, is
  // that curve, as a sphere's outline is; any other is a spline. Each edge
  // has the tolerance measured.
  if (const auto exact = exactCurve(samples, surface, onContour)) {
    built.add(exact->curve, exact->first, exact->last, start, end, exact->tolerance);
    return;
  }
  const Fit fit = fitContour(samples, surface, onContour, locate);
  built.add(fit.curve, fit.at.front(), fit.at.back(), start, end, fit.tolerance);
}

// Ends a run of a path inside the face. Points in a row no farther apart
// than OCCT tells are one, as where a node lies on the contour and the
// crossings of the edges at it meet there; a run of one point is no
// curve. The run is cut where the contour is: on an edge of the face,
// where it reaches the face's boundary, or a singular point, all of whose
// edge on the face's parameters stands for the one point, so that the
// parameters tell nothing of the way on; and where it crosses itself. A
// run that comes back to its first point on the face's parameters is a
// loop, cut likewise; one whose ends meet only in space, across a seam,
// is not.
void GridTrace::finish(Piece run) {
  Piece merged;
  for (size_t k = 0; k < run.points.size(); ++k) {
    if (!merged.points.empty() && merged.points.back().p.Distance(run.points[k].p) <= Precision::Confusion()) {
      merged.points.back().edge = merged.points.back().edge || run.points[k].edge;
      merged.points.back().cut = merged.points.back().cut || run.points[k].cut;
      continue;
    }
    if (!merged.points.empty())
      merged.through.push_back(run.through[k - 1]);
    merged.points.push_back(run.points[k]);
  }
  auto &points = merged.points;
  auto &through = merged.through;
  if (points.size() < 2)
    return;
  if (points.size() > 2 && points.front().uv.Distance(points.back().uv) <= Precision::PConfusion()) {
    points.front().edge = points.front().edge || points.back().edge;
    points.front().cut = points.front().cut || points.back().cut;
    points.pop_back();
    const auto first = std::find_if(points.begin(), points.end(), [](const Sample &s) { return s.cut; });
    if (first == points.end()) {
      points.push_back(points.front());
      trace(std::move(merged), true);
      return;
    }
    const auto turn = first - points.begin();
    std::rotate(points.begin(), first, points.end());
    std::rotate(through.begin(), through.begin() + turn, through.end());
    points.push_back(points.front());
  }
  for (size_t from = 0, k = 1; k < points.size(); ++k) {
    if (!points[k].cut && k + 1 < points.size())
      continue;
    Piece piece;
    piece.points.assign(points.begin() + static_cast<std::ptrdiff_t>(from), points.begin() + static_cast<std::ptrdiff_t>(k + 1));
    piece.through.assign(through.begin() + static_cast<std::ptrdiff_t>(from), through.begin() + static_cast<std::ptrdiff_t>(k));
    from = k;
    trace(std::move(piece), false);
  }
}

std::vector<TopoDS_Edge> GridTrace::edges() {
  for (const auto &path : paths) {
    Piece run;
    bool inside = false;
    for (size_t k = 0; k < path.at.size(); ++k) {
      const Crossing &c = crossings[path.at[k]];
      const TopAbs_State state = classifier.Perform(c.uv);
      const bool in = state != TopAbs_OUT;
      if (k > 0 && in != inside) {
        const Crossing &before = crossings[path.at[k - 1]];
        const auto edgePoint = in ? leaving(c.uv, before.uv) : leaving(before.uv, c.uv);
        if (inside) {
          if (edgePoint) {
            run.points.push_back(*edgePoint);
            run.through.push_back(path.through[k - 1]);
          }
          finish(std::move(run));
          run = {};
        } else if (edgePoint) {
          run.points = {*edgePoint};
        }
      }
      if (in) {
        if (!run.points.empty())
          run.through.push_back(path.through[k - 1]);
        const bool edge = onEdge(c.uv, state);
        run.points.push_back({c.uv, c.p, edge, edge || (c.node && critical[*c.node])});
      }
      inside = in;
    }
    finish(std::move(run));
  }
  requireClosedEnds(face, built.edges);
  return built.edges;
}
} // namespace huak::space::contour
