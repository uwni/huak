// The two exact projected curves have a shared endpoint and a crossing a few
// millionths away, which OCCT's own curve intersector does not tell from
// it. The arrangement keeps both: two vertices at which arcs of both curves
// end, so that the small region between them stays bounded; losing one of
// these incidences used to leave a region's boundary crossing itself.
#include "../src/drawing/space/space.hxx"
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <algorithm>
#include <Geom_BSplineCurve.hxx>
#include <NCollection_Array1.hxx>
#include <TopExp.hxx>
#include <cstdio>

int main() {
  const gp_Pnt first[] = {
      {-22.51423950163073, 3.6745742715379239, 0},
      {-22.481283512812013, 3.6200111662832239, 0},
      {-22.458860727876246, 3.5768462583609968, 0},
      {-22.44529107047779, 3.5454264079015503, 0},
      {-22.438484925666806, 3.5256858330061638, 0},
      {-22.435876534026978, 3.5169768460387383, 0},
      {-22.434343744096331, 3.5178471139480347, 0}};
  const gp_Pnt second[] = {
      {-22.434343744096331, 3.5178471139480347, 0},
      {-22.433981388967055, 3.5158969837119689, 0},
      {-22.480876146613571, 3.6613754528657254, 0},
      {-22.439441206355486, 3.8154524433091592, 0},
      {-22.434757415199201, 3.8296978566705318, 0}};
  auto edge = [](const auto &points, double start) {
    const int n = sizeof(points) / sizeof(points[0]);
    NCollection_Array1<gp_Pnt> poles(1, n);
    for (int i = 0; i < n; ++i)
      poles(i + 1) = points[i];
    NCollection_Array1<double> knots(1, 2);
    knots(1) = start;
    knots(2) = 1;
    NCollection_Array1<int> multiplicities(1, 2);
    multiplicities.Init(n);
    return BRepBuilderAPI_MakeEdge(
               new Geom_BSplineCurve(poles, knots, multiplicities, n - 1))
        .Edge();
  };
  const std::vector<TopoDS_Edge> images{edge(first, 0.95120232690684425), edge(second, 0)};
  const auto arcs = huak::space::arrangeImages(images, {true, true}, {}, {});
  // The vertices at which arcs of both curves end: the shared end, and the
  // crossing beside it that bounds the small region between them.
  std::vector<std::pair<TopoDS_Vertex, int>> ends;
  for (const auto &arc : arcs) {
    int of = 0;
    for (const auto &part : arc.parts)
      of |= 1 << part.tool;
    TopoDS_Vertex a, b;
    TopExp::Vertices(arc.edge, a, b);
    for (const auto &vertex : {a, b}) {
      const auto known = std::find_if(ends.begin(), ends.end(), [&](const auto &end) { return end.first.IsSame(vertex); });
      if (known == ends.end())
        ends.push_back({vertex, of});
      else
        known->second |= of;
    }
  }
  const auto shared = std::count_if(ends.begin(), ends.end(), [](const auto &end) { return end.second == 3; });
  if (shared != 2) {
    std::fprintf(stderr, "arcs of both curves end at %td vertices, expected the shared end and the crossing\n", shared);
    return 1;
  }
}
