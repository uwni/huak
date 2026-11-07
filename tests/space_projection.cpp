// The two exact projected curves have a shared endpoint and a nearby crossing.
// Recovering the crossing parameter with a point-to-curve nearest-point query
// used to lose one incidence and produce a self-intersecting face boundary.
#include "../src/drawing/space/result.hxx"
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <Geom_BSplineCurve.hxx>
#include <NCollection_Array1.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <gp_Pln.hxx>
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
  huak::space::ShapeList objects, tools;
  objects.Append(BRepBuilderAPI_MakeFace(gp_Pln(gp::XOY()), -24, -21, 2, 5).Face());
  tools.Append(edge(first, 0.95120232690684425));
  tools.Append(edge(second, 0));
  const auto partition = huak::space::splitFaces(objects, tools);
  int cells = 0, small = 0;
  for (TopExp_Explorer it(partition, TopAbs_FACE); it.More(); it.Next()) {
    ++cells;
    if (!BRepCheck_Analyzer(it.Current()).IsValid()) {
      std::fprintf(stderr, "projected cell has an invalid boundary\n");
      return 1;
    }
    GProp_GProps area;
    BRepGProp::SurfaceProperties(it.Current(), area);
    small += area.Mass() > 0 && area.Mass() < 1e-9;
  }
  if (cells != 2 || small != 1) {
    std::fprintf(stderr, "lost the closed region between the two crossings\n");
    return 1;
  }
}
