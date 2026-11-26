// The regions that sets of arcs bound, on arcs laid out as the arrangement
// leaves them: straight arcs whose ends stand anywhere within the vertices
// at them, not at the vertices' points.
//
// A cell between two straight arcs that meet at the same two vertices, no
// wider than those vertices reach: at the vertices' points it is one
// segment run there and back, and only where the arcs stand apart, beyond
// the vertices, does it bound anything. It is a region, not a hole. The
// arcs and vertices are the arrangement's near the apex of bench.huak's
// cone under its light 3 (elevation 63.26°, azimuth -56.32°, spot 24°),
// where OCCT's classifier, given three points of the loop, took it for a
// hole.
//
// Two rings, one within the hole of the other, far from the origin, the
// inner ring's square with its arcs' ends a little off its corners, within
// the vertices there: an area taken from the arcs as OCCT integrates them,
// which then do not close, moves by about the gaps times the distance from
// the origin, here more than the inner ring is wide. Each hole is the
// inner ring's or the outer's only by what lies within what.
#include "../src/drawing/space/view.hxx"
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2d_Line.hxx>
#include <cstdio>

namespace {
using huak::space::entry::leaving;
using huak::space::entry::regions;

BRep_Builder builder;

TopoDS_Vertex vertexAt(const gp_Pnt2d &at, double reach) {
  TopoDS_Vertex vertex;
  builder.MakeVertex(vertex, gp_Pnt(at.X(), at.Y(), 0), reach);
  return vertex;
}

// A straight arc from p to q, its ends at the vertices given, as the
// arrangement makes one: its edge, its curve on the plane, the polyline of
// its ends, and where it leaves the vertices.
HuakView::Arc lineArc(const TopoDS_Vertex &from, const TopoDS_Vertex &to, const gp_Pnt2d &p, const gp_Pnt2d &q,
                      double tolerance) {
  const double length = p.Distance(q);
  const gp_Dir2d way(gp_Vec2d(p, q));
  TopoDS_Edge edge;
  builder.MakeEdge(edge, new Geom_Line(gp_Pnt(p.X(), p.Y(), 0), gp_Dir(way.X(), way.Y(), 0)), tolerance);
  builder.Add(edge, from.Oriented(TopAbs_FORWARD));
  builder.Add(edge, to.Oriented(TopAbs_REVERSED));
  builder.Range(edge, 0, length);
  HuakView::Arc arc;
  arc.edge = edge;
  arc.curve = new Geom2dAdaptor_Curve(new Geom2d_Line(p, way));
  arc.first = 0;
  arc.last = length;
  arc.blur = tolerance;
  arc.at = {0, length};
  arc.points = {p, q};
  arc.offs = {0};
  arc.box.Add(p.XY());
  arc.box.Add(q.XY());
  const gp_Pnt tail = BRep_Tool::Pnt(from), head = BRep_Tool::Pnt(to);
  arc.tail = gp_Pnt2d(tail.X(), tail.Y());
  arc.head = gp_Pnt2d(head.X(), head.Y());
  arc.tailReach = BRep_Tool::Tolerance(from);
  arc.headReach = BRep_Tool::Tolerance(to);
  arc.tailLeaves = leaving(arc, true, arc.tail, arc.tailReach);
  arc.headLeaves = leaving(arc, false, arc.head, arc.headReach);
  double first = 0, last = length;
  BRepLib::FindValidRange(edge, first, last);
  arc.middle = (first + last) / 2;
  return arc;
}

// The closed paths of each region of one set of arcs.
std::vector<int> loopsPerRegion(HuakView &view, const std::vector<HuakTurnedArc> &arcs, std::string &error) {
  const size_t offsets[] = {0, arcs.size()};
  HuakRegions out{};
  char message[512] = {};
  if (regions(&view, offsets, arcs.data(), 1, 0.01, 1, &out, message, sizeof message) != HUAK_SPACE_OK) {
    error = message;
    return {};
  }
  std::vector<int> loops;
  for (size_t r = out.sets[0]; r < out.sets[1]; ++r) {
    int closed = 0;
    for (size_t c = out.offsets[r]; c < out.offsets[r + 1]; ++c)
      closed += out.commands[c].op == HUAK_CLOSE;
    loops.push_back(closed);
  }
  return loops;
}

// The cell between two of the cone's arcs near its apex.
int apexCell() {
  HuakModel model;
  HuakView view(model, gp_Ax2(), 0);
  const TopoDS_Vertex wide = vertexAt({-2.85678709205e-05, 17.0977928915}, 3.26e-06);
  const TopoDS_Vertex narrow = vertexAt({-2.25766696892e-05, 17.0977992311}, 1.65e-06);
  // The contours' arc, from the wide vertex to the narrow one, and the
  // outline's, the same way, the cell lying left of the first.
  view.arcs.push_back(lineArc(wide, narrow, {-2.64516335913e-05, 17.0977936906}, {-2.16062912592e-05, 17.0977981506}, 8.98e-07));
  view.arcs.push_back(lineArc(wide, narrow, {-2.92310804882e-05, 17.0977936877}, {-2.25766696892e-05, 17.0977992311}, 1e-07));
  std::string error;
  const auto loops = loopsPerRegion(view, {{0, 0}, {1, 1}}, error);
  if (loops.size() != 1 || loops[0] != 1) {
    std::fprintf(stderr, "apex cell: %zu regions, expected one bound by one loop%s%s\n", loops.size(),
                 error.empty() ? "" : ": ", error.c_str());
    return 1;
  }
  std::printf("apex cell: one region, bound by one loop\n");
  return 0;
}

// The square of half side `half` about the centre, counterclockwise or
// clockwise, each arc's ends `gap` off the corners along y, past them on
// the way in and short of them on the way out, within vertices reaching
// `reach`.
std::vector<HuakTurnedArc> square(HuakView &view, const gp_Pnt2d &centre, double half, bool counterclockwise, double gap,
                                  double reach) {
  std::vector<gp_Pnt2d> corners{{centre.X() - half, centre.Y() - half},
                                {centre.X() + half, centre.Y() - half},
                                {centre.X() + half, centre.Y() + half},
                                {centre.X() - half, centre.Y() + half}};
  if (!counterclockwise)
    std::reverse(corners.begin(), corners.end());
  std::vector<TopoDS_Vertex> vertices;
  for (const auto &corner : corners)
    vertices.push_back(vertexAt(corner, reach));
  std::vector<HuakTurnedArc> arcs;
  for (size_t i = 0; i < 4; ++i) {
    const gp_Pnt2d &a = corners[i], &b = corners[(i + 1) % 4];
    view.arcs.push_back(lineArc(vertices[i], vertices[(i + 1) % 4], {a.X(), a.Y() + gap / 2}, {b.X(), b.Y() - gap / 2}, 1e-7));
    arcs.push_back({view.arcs.size() - 1, 0});
  }
  return arcs;
}

// Two rings, the inner within the outer's hole, the inner ring's square
// with gaps at its corners, all a long way from the origin.
int nestedRings() {
  HuakModel model;
  HuakView view(model, gp_Ax2(), 0);
  const gp_Pnt2d centre(1e4, 1e4);
  const double reach = 1e-6, width = 2e-4;
  std::vector<HuakTurnedArc> arcs;
  for (const auto &loop : {square(view, centre, 4, true, 0, reach), square(view, centre, 3, false, 0, reach),
                           square(view, centre, 2, true, 5e-7, reach), square(view, centre, 2 - width, false, 0, reach)})
    arcs.insert(arcs.end(), loop.begin(), loop.end());
  std::string error;
  const auto loops = loopsPerRegion(view, arcs, error);
  if (loops.size() != 2 || loops[0] != 2 || loops[1] != 2) {
    std::fprintf(stderr, "nested rings: %zu regions bound by", loops.size());
    for (const int n : loops)
      std::fprintf(stderr, " %d", n);
    std::fprintf(stderr, " loops, expected two rings of two loops each%s%s\n", error.empty() ? "" : ": ", error.c_str());
    return 1;
  }
  std::printf("nested rings: two rings, each bound by its own two loops\n");
  return 0;
}

// `compute_moments = 0` skips BRepGProp and returns null `moments` while
// matching loops and bounds identically; `compute_moments = 1` populates them.
int momentsOption() {
  HuakModel model;
  HuakView view(model, gp_Ax2(), 0);
  const auto arcs = square(view, {0, 0}, 3, true, 0, 1e-6);
  const size_t offsets[] = {0, arcs.size()};
  HuakRegions without{}, with{};
  char message[512] = {};
  if (regions(&view, offsets, arcs.data(), 1, 0.01, 0, &without, message, sizeof message) != HUAK_SPACE_OK) {
    std::fprintf(stderr, "moments option (off): %s\n", message);
    return 1;
  }
  if (regions(&view, offsets, arcs.data(), 1, 0.01, 1, &with, message, sizeof message) != HUAK_SPACE_OK) {
    std::fprintf(stderr, "moments option (on): %s\n", message);
    return 1;
  }
  if (without.moments != nullptr || with.moments == nullptr) {
    std::fprintf(stderr, "moments option: unexpected moments pointer (off=%p, on=%p)\n",
                 static_cast<const void *>(without.moments), static_cast<const void *>(with.moments));
    return 1;
  }
  if (without.count != 1 || with.count != 1 || without.sets[0] != 0 || without.sets[1] != 1 || with.sets[0] != 0 ||
      with.sets[1] != 1) {
    std::fprintf(stderr, "moments option: unexpected region counts\n");
    return 1;
  }
  const size_t n = without.offsets[1];
  if (n != with.offsets[1] || without.bounds[0].empty != with.bounds[0].empty ||
      without.bounds[0].x0 != with.bounds[0].x0 || without.bounds[0].y0 != with.bounds[0].y0 ||
      without.bounds[0].x1 != with.bounds[0].x1 || without.bounds[0].y1 != with.bounds[0].y1) {
    std::fprintf(stderr, "moments option: loops or bounds differ\n");
    return 1;
  }
  for (size_t i = 0; i < n; ++i) {
    const auto &a = without.commands[i], &b = with.commands[i];
    if (a.op != b.op || a.p[0].x != b.p[0].x || a.p[0].y != b.p[0].y || a.p[1].x != b.p[1].x ||
        a.p[1].y != b.p[1].y || a.p[2].x != b.p[2].x || a.p[2].y != b.p[2].y) {
      std::fprintf(stderr, "moments option: path command %zu differs\n", i);
      return 1;
    }
  }
  if (std::abs(with.moments[0].area - 36.0) > 1e-5 || std::abs(with.moments[0].center[0]) > 1e-5 ||
      std::abs(with.moments[0].center[1]) > 1e-5) {
    std::fprintf(stderr, "moments option: unexpected moments area=%g center=(%g,%g)\n", with.moments[0].area,
                 with.moments[0].center[0], with.moments[0].center[1]);
    return 1;
  }
  std::printf("moments option: skipped when off, populated when on\n");
  return 0;
}

// A revolved vase seen from elevation 50 deg, azimuth 20 deg: its apparent
// contour folds smoothly into Whitney cusps. Each visible face's boundary loop
// turns once (+1) with no self-crossing error in `regions()`.
int whitneyCusp() {
  const HuakProjectionV7 *api = huak_space_api_v7();
  // Exact cubic Bézier meridian of the revolved vase in XZ:
  // (0,0)--(9,0)~~(14,11)~~(5.5,27)~~(9,38)--(0,38)--cycle.
  const HuakPathCommand profile[] = {
      {HUAK_MOVE, {{0, 0}}},
      {HUAK_LINE, {{9, 0}}},
      {HUAK_BEZIER, {{12.767287704, 2.292111212}, {14.750187577, 6.654490933}, {14, 11}}},
      {HUAK_BEZIER, {{12.948511322, 17.090814785}, {6.88595894, 21.001771112}, {5.5, 27}}},
      {HUAK_BEZIER, {{4.568645734, 31.030765922}, {5.910666023, 35.248543973}, {9, 38}}},
      {HUAK_LINE, {{0, 38}}},
      {HUAK_CLOSE, {}},
  };
  HuakModelShape shape{};
  shape.kind = HUAK_REVOLVE;
  shape.args[5] = 1.0;
  shape.args[6] = 2.0 * M_PI;
  shape.u[0] = 1.0;
  shape.v[2] = 1.0;
  shape.profile = profile;
  shape.count = sizeof(profile) / sizeof(profile[0]);
  const size_t root = 0;
  HuakModel *model = nullptr;
  char message[512] = {};
  if (api->build(&shape, 1, &root, 1, 0.01, &model, message, sizeof message) != HUAK_SPACE_OK) {
    std::fprintf(stderr, "whitney cusp build: %s\n", message);
    return 1;
  }
  const double az = 20.0 * M_PI / 180.0, el = 50.0 * M_PI / 180.0;
  const double eye[3] = {std::cos(el) * std::cos(az), std::cos(el) * std::sin(az), std::sin(el)};
  const double x[3] = {-std::sin(az), std::cos(az), 0.0};
  HuakView *view = nullptr;
  HuakFrame frame{};
  int status = 1;
  do {
    if (api->view(model, eye, x, 0.0, &view, &frame, message, sizeof message) != HUAK_SPACE_OK)
      break;
    HuakEdges edges{};
    HuakRims rims{};
    if (api->edges(view, 0, &edges, message, sizeof message) != HUAK_SPACE_OK ||
        api->rims(view, 0, &rims, message, sizeof message) != HUAK_SPACE_OK)
      break;
    std::vector<size_t> curves;
    for (size_t i = 0; i < edges.count; ++i)
      if (!(edges.items[i].faces == 1 && edges.items[i].closed != 0))
        curves.push_back(edges.items[i].curve);
    for (size_t i = 0; i < rims.count; ++i)
      if (std::find(curves.begin(), curves.end(), rims.items[i].curve) == curves.end())
        curves.push_back(rims.items[i].curve);
    std::vector<ptrdiff_t> projected(curves.size(), -1);
    if (api->project(view, curves.data(), curves.size(), 0, 0.01, projected.data(), message, sizeof message) !=
        HUAK_SPACE_OK)
      break;
    std::vector<size_t> images;
    for (const ptrdiff_t img : projected)
      if (img >= 0)
        images.push_back(static_cast<size_t>(img));
    HuakArcs arcs{};
    HuakCells cells{};
    if (api->arrange(view, images.data(), images.size(), nullptr, 0, &arcs, message, sizeof message) != HUAK_SPACE_OK ||
        api->cells(view, &cells, message, sizeof message) != HUAK_SPACE_OK)
      break;
    std::map<std::pair<size_t, size_t>, std::vector<HuakTurnedArc>> byLayer;
    for (size_t k = 0; k < cells.arcs; ++k) {
      const size_t la = cells.offsets[cells.left[k]], lb = cells.offsets[cells.left[k] + 1];
      const size_t ra = cells.offsets[cells.right[k]], rb = cells.offsets[cells.right[k] + 1];
      const size_t depth = std::max(lb - la, rb - ra);
      for (size_t c = 0; c < depth; ++c) {
        const ptrdiff_t l = c < lb - la ? static_cast<ptrdiff_t>(cells.layers[la + c].face) : -1;
        const ptrdiff_t r = c < rb - ra ? static_cast<ptrdiff_t>(cells.layers[ra + c].face) : -1;
        if (l == r)
          continue;
        if (l >= 0)
          byLayer[{c, static_cast<size_t>(l)}].push_back({k, 0});
        if (r >= 0)
          byLayer[{c, static_cast<size_t>(r)}].push_back({k, 1});
      }
    }
    std::vector<size_t> offsets{0};
    std::vector<HuakTurnedArc> turned;
    for (const auto &[key, list] : byLayer) {
      turned.insert(turned.end(), list.begin(), list.end());
      offsets.push_back(turned.size());
    }
    HuakRegions out{};
    if (api->regions(view, offsets.data(), turned.data(), byLayer.size(), 0.01, 0, &out, message, sizeof message) !=
        HUAK_SPACE_OK)
      break;
    if (out.count == 0 || out.sets[out.count] == 0) {
      std::snprintf(message, sizeof message, "expected visible regions");
      break;
    }
    status = 0;
  } while (false);
  if (status != 0)
    std::fprintf(stderr, "whitney cusp: %s\n", message);
  else
    std::printf("whitney cusp: all visible face regions turn once\n");
  if (view)
    api->release_view(view);
  api->release_model(model);
  return status;
}
} // namespace

int main() { return apexCell() + nestedRings() + momentsOption() + whitneyCusp() == 0 ? 0 : 1; }
