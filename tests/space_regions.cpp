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
  if (regions(&view, offsets, arcs.data(), 1, 0.01, &out, message, sizeof message) != HUAK_SPACE_OK) {
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
} // namespace

int main() { return apexCell() + nestedRings() == 0 ? 0 : 1; }
