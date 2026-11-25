// The cells of the arrangement and the layers over each.
#include "view.hxx"

namespace {
// The direction from the vertex at `centre` toward an arc's point at t,
// where it leaves the vertex: beyond a vertex's reach the arcs that meet
// there stand apart, so these directions keep the order in which they
// leave it.
double outward(const HuakView::Arc &arc, double t, const gp_Pnt2d &centre) {
  const gp_Pnt2d p = arc.curve->Value(t);
  return std::atan2(p.Y() - centre.Y(), p.X() - centre.X());
}

// How far a point stands from a box.
double fromBox(const gp_Pnt2d &p, const Bnd_B2<double> &box) {
  const gp_XY low = box.CornerMin(), high = box.CornerMax();
  const double dx = std::max({0.0, low.X() - p.X(), p.X() - high.X()});
  const double dy = std::max({0.0, low.Y() - p.Y(), p.Y() - high.Y()});
  return std::sqrt(dx * dx + dy * dy);
}

// How far the middle of an arc stands from the rest of the arrangement, less
// the tolerances of the images, and never less than nothing: from every
// other arc, and from its own beyond the part of its polyline that holds
// the middle and the parts on either side of that, those three ending
// where the rest begins. Along each part of its polyline an arc heads
// within `turning` of one way, so along three it does not come back to the
// normal through the middle: a point on the normal, half as far from the
// middle, stands nearly half as far from every arc.
//
// The polylines bound how near each part of an arc may come, and its ends
// how near it comes at most; a part whose bound allows it no nearer than
// another comes is not the nearest. Unrefined, the clearance is what the
// bounds allow; refined, OCCT finds how near the parts come, the part
// bounded nearest first, while a part's bound allows it nearer than found.
double clearance(const HuakView &view, size_t k, bool refined) {
  const auto &arc = view.arcs[k];
  const gp_Pnt2d middle = arc.curve->Value(arc.middle);
  const size_t last = arc.points.size() - 1;
  const size_t holding = static_cast<size_t>(std::clamp<std::ptrdiff_t>(
      std::upper_bound(arc.at.begin(), arc.at.end(), arc.middle) - arc.at.begin() - 1, 0,
      static_cast<std::ptrdiff_t>(last) - 1));
  const size_t from = holding == 0 ? 0 : holding - 1, to = std::min(last, holding + 2);
  double most = std::min(middle.Distance(arc.points[from]), middle.Distance(arc.points[to])) - arc.blur;
  struct Part {
    double bound;
    size_t arc, segment;
  };
  std::vector<Part> parts;
  for (size_t j = 0; j < view.arcs.size(); ++j) {
    const auto &other = view.arcs[j];
    if (fromBox(middle, other.box) >= most)
      continue;
    for (size_t s = 0; s < other.points.size() - 1; ++s) {
      if (j == k && from <= s && s < to)
        continue;
      const gp_Pnt2d &a = other.points[s], &b = other.points[s + 1];
      most = std::min(most, std::min(middle.Distance(a), middle.Distance(b)) - other.blur);
      const double bound = apart(middle, a, b) - other.offs[s] - other.blur;
      if (bound < most)
        parts.push_back({bound, j, s});
    }
  }
  std::sort(parts.begin(), parts.end(), [](const Part &x, const Part &y) { return x.bound < y.bound; });
  if (!refined)
    return std::max(0.0, parts.empty() ? most : std::min(most, parts.front().bound));
  double least = most;
  for (const auto &part : parts) {
    if (part.bound >= least)
      break;
    const auto &other = view.arcs[part.arc];
    const size_t s = part.segment;
    Extrema_ExtPC2d nearest(middle, *other.curve, other.at[s], other.at[s + 1]);
    double found = part.bound + other.blur;
    if (nearest.IsDone()) {
      found = std::min(middle.Distance(other.points[s]), middle.Distance(other.points[s + 1]));
      for (int i = 1; i <= nearest.NbExt(); ++i)
        found = std::min(found, std::sqrt(nearest.SquareDistance(i)));
    }
    least = std::min(least, found - other.blur);
  }
  return std::max(0.0, least);
}

// The layers that the line of sight through a point of the plane meets,
// front to back.
std::vector<HuakLayer> layersAt(HuakView *view, const gp_Pnt2d &at) {
  std::vector<huak::space::Sight> met;
  view->sights().meet(at, met);
  std::vector<HuakLayer> layers;
  for (const auto &sight : met) {
    const TopoDS_Face &face = faceOf(&view->model, sight.source, sight.face);
    gp_Dir normal;
    if (!normalOf(BRep_Tool::Surface(face), face.Orientation() == TopAbs_REVERSED, gp_Pnt2d(sight.u, sight.v), normal))
      throw std::runtime_error("undefined surface normal inside a cell");
    layers.push_back({sight.source, sight.face, gp_Vec(normal).Dot(view->toward(sight.point)) > 0 ? 1 : -1,
                      view->depth(sight.point), sight.u, sight.v});
  }
  std::sort(layers.begin(), layers.end(), [](const HuakLayer &a, const HuakLayer &b) { return a.depth > b.depth; });
  return layers;
}
} // namespace

namespace huak::space::entry {
// The cells of the arrangement, with their layers. Arc k runs from its tail
// as half-edge 2k and from its head, the other way, as half-edge 2k + 1,
// each with its left on the left of the way it runs. Come along a
// half-edge to a vertex, the path around the part of the plane on its left
// turns onto the half-edge that leaves the vertex next clockwise from the
// way back; each closed path is a cell. The point of a cell whose line of
// sight gives its layers lies on the normal through the middle of the arc
// of its boundary that stands clearest of the rest, halfway out.
int cells(HuakView *view, HuakCells *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    const auto &arcs = view->arcs;
    const size_t n = arcs.size();
    std::map<const void *, std::vector<std::pair<double, size_t>>> around;
    for (size_t k = 0; k < n; ++k) {
      TopoDS_Vertex tail, head;
      TopExp::Vertices(arcs[k].edge, tail, head);
      around[tail.TShape().get()].push_back({outward(arcs[k], arcs[k].tailLeaves, arcs[k].tail), 2 * k});
      around[head.TShape().get()].push_back({outward(arcs[k], arcs[k].headLeaves, arcs[k].head), 2 * k + 1});
    }
    std::vector<size_t> next(2 * n);
    for (auto &[vertex, leaves] : around) {
      std::sort(leaves.begin(), leaves.end());
      for (size_t i = 0; i < leaves.size(); ++i)
        next[leaves[i].second ^ 1] = leaves[(i + leaves.size() - 1) % leaves.size()].second;
    }
    constexpr size_t none = std::numeric_limits<size_t>::max();
    std::vector<size_t> cellOf(2 * n, none);
    size_t count = 0;
    for (size_t h = 0; h < 2 * n; ++h) {
      if (cellOf[h] != none)
        continue;
      for (size_t g = h; cellOf[g] == none; g = next[g])
        cellOf[g] = count;
      ++count;
    }
    // Each cell's arc stands clearest as the polylines bound it; OCCT then
    // finds how clear it stands.
    std::vector<double> clear(n);
    for (size_t k = 0; k < n; ++k)
      clear[k] = clearance(*view, k, false);
    std::vector<size_t> clearest(count, none);
    for (size_t h = 0; h < 2 * n; ++h) {
      size_t &best = clearest[cellOf[h]];
      if (best == none || clear[h / 2] > clear[best / 2])
        best = h;
    }
    std::vector<bool> refined(n, false);
    for (const size_t h : clearest)
      if (!refined[h / 2]) {
        clear[h / 2] = clearance(*view, h / 2, true);
        refined[h / 2] = true;
      }
    auto &offsets = view->result(view->indices);
    auto &layers = view->result(view->layerItems);
    offsets.push_back(0);
    for (size_t cell = 0; cell < count; ++cell) {
      const size_t h = clearest[cell];
      const auto &arc = arcs[h / 2];
      gp_Pnt2d middle;
      gp_Vec2d along;
      arc.curve->D1(arc.middle, middle, along);
      if (!(along.Magnitude() > gp::Resolution()))
        throw std::runtime_error("an arc stands still at its middle");
      gp_Vec2d side(-along.Y(), along.X());
      if (h % 2)
        side.Reverse();
      side.Normalize();
      const auto found = layersAt(view, middle.Translated(side * (clear[h / 2] / 2)));
      layers.insert(layers.end(), found.begin(), found.end());
      offsets.push_back(layers.size());
    }
    auto &left = view->result(view->indices);
    auto &right = view->result(view->indices);
    for (size_t k = 0; k < n; ++k) {
      left.push_back(cellOf[2 * k]);
      right.push_back(cellOf[2 * k + 1]);
    }
    *out = {offsets.data(), layers.data(), count, left.data(), right.data(), n};
  });
}
} // namespace huak::space::entry
