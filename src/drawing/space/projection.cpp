// OCCT owns modelling, silhouettes and hidden-line classification. Only final
// projected edges are approximated to Huak's polynomial path representation.
#include "result.hxx"
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepLib.hxx>
#include <BRep_Tool.hxx>
#include <GeomConvert.hxx>
#include <GeomConvert_ApproxCurve.hxx>
#include <GeomConvert_BSplineCurveToBezierCurve.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_Line.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

namespace huak::space {
static HuakXY xy(const gp_Pnt &p) { return {p.X(), p.Y()}; }

// Apply the camera to the homogeneous poles after HLR trims the space curve.
// This keeps perspective conics rational until the final path conversion.
TopoDS_Edge projected(const TopoDS_Edge &edge,
                      const HLRAlgo_Projector &projector, double tolerance) {
  if (BRep_Tool::Degenerated(edge))
    return {};
  double a, b;
  if (!BRepLib::BuildCurve3d(edge, std::min(tolerance, Precision::Confusion())))
    throw std::runtime_error("missing source curve");
  auto curve = BRep_Tool::Curve(edge, a, b);
  if (curve.IsNull())
    throw std::runtime_error("missing source curve");
  auto plane = [&](gp_Pnt p, double &weight) {
    projector.Transform(p);
    const double w =
        projector.Perspective() ? 1.0 - p.Z() / projector.Focus() : 1.0;
    if (w <= 0)
      throw std::domain_error("shape crosses the camera eye plane");
    weight *= w;
    return gp_Pnt(p.X() / w, p.Y() / w, 0);
  };
  if (curve->IsKind(STANDARD_TYPE(Geom_Line))) {
    double weight = 1;
    auto start = plane(curve->Value(a), weight),
         end = plane(curve->Value(b), weight);
    if (start.Distance(end) <= Precision::Confusion())
      return {};
    return BRepBuilderAPI_MakeEdge(start, end);
  }
  auto spline =
      GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(curve, a, b));
  bool collapsed = true;
  for (int i = 1; i <= spline->NbPoles(); ++i) {
    double weight = spline->Weight(i);
    const auto p = plane(spline->Pole(i), weight);
    spline->SetPole(i, p, weight);
    if (spline->Pole(1).Distance(p) > Precision::Confusion())
      collapsed = false;
  }
  if (collapsed)
    return {};
  return BRepBuilderAPI_MakeEdge(spline);
}

void writeEdge(Result &result, const TopoDS_Edge &edge, double tolerance,
               bool move) {
  double first, last;
  const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
  if (curve.IsNull())
    throw std::runtime_error("missing projected curve");
  Handle(Geom_TrimmedCurve) portion = new Geom_TrimmedCurve(curve, first, last);
  if (edge.Orientation() == TopAbs_REVERSED)
    portion->Reverse();
  if (move)
    result.commands.push_back({HUAK_MOVE, {xy(portion->StartPoint())}});
  if (curve->IsKind(STANDARD_TYPE(Geom_Line))) {
    result.commands.push_back({HUAK_LINE, {xy(portion->EndPoint())}});
    return;
  }
  GeomConvert_ApproxCurve approx(portion, tolerance, GeomAbs_C0, 1024, 3);
  if (!approx.IsDone() || approx.MaxError() > tolerance)
    throw std::runtime_error("projected curve exceeded tolerance");
  GeomConvert_BSplineCurveToBezierCurve split(approx.Curve());
  for (int i = 1; i <= split.NbArcs(); ++i) {
    auto arc = split.Arc(i);
    arc->Increase(3);
    result.commands.push_back(
        {HUAK_BEZIER, {xy(arc->Pole(2)), xy(arc->Pole(3)), xy(arc->Pole(4))}});
  }
}
} // namespace huak::space

extern "C" int huak_space_project(const HuakModelShape *input,
                                  size_t node_count, const size_t *roots,
                                  size_t count, double azimuth,
                                  double elevation, double focus,
                                  double tolerance, int include_faces,
                                  HuakLinework *output, char *error,
                                  size_t capacity) {
  using namespace huak::space;
  *output = {};
  try {
    auto result = std::make_unique<Result>();
    const gp_Dir direction(cos(elevation) * cos(azimuth),
                           cos(elevation) * sin(azimuth), sin(elevation));
    const gp_Ax2 axes(gp::Origin(), direction,
                      gp_Dir(-sin(azimuth), cos(azimuth), 0));
    const auto projector =
        focus == 0 ? HLRAlgo_Projector(axes) : HLRAlgo_Projector(axes, focus);
    std::vector<TopoDS_Shape> shapes;
    std::vector<TopoDS_Shape> nodes;
    nodes.reserve(node_count);
    for (size_t i = 0; i < node_count; ++i)
      nodes.push_back(buildShape(input[i], nodes, tolerance));
    std::vector<TopoDS_Edge> cell_boundaries;
    std::vector<Feature> features;
    for (size_t i = 0; i < count; ++i) {
      shapes.push_back(nodes.at(roots[i]));
      const auto &shape = shapes.back();
      if (!TopExp_Explorer(shape, TopAbs_FACE).More()) {
        for (TopExp_Explorer e(shape, TopAbs_EDGE); e.More(); e.Next())
          features.push_back(
              {i, HUAK_CURVE, std::nullopt, TopoDS::Edge(e.Current())});
        continue;
      }
      // HLR handles the shape's own silhouette and self-occlusion. Independent
      // surfaces can intersect in space, so classify between shapes after
      // splitting the curves at both projected borders and 3D intersections.
      Handle(HLRBRep_Algo) algo = new HLRBRep_Algo();
      algo->Projector(projector);
      algo->Add(shape);
      algo->Update();
      algo->Hide();
      HLRBRep_HLRToShape extract(algo);
      const HLRBRep_TypeOfResultingEdge kinds[] = {
          HLRBRep_Sharp, HLRBRep_OutLine, HLRBRep_Rg1Line, HLRBRep_RgNLine};
      for (int kind = 0; kind < 4; ++kind)
        for (bool visible : {true, false}) {
          auto group =
              extract.CompoundOfEdges(shape, kinds[kind], visible, true);
          for (TopExp_Explorer e(group, TopAbs_EDGE); e.More(); e.Next())
            features.push_back({i, kind, visible, TopoDS::Edge(e.Current())});
        }
    }
    Surfaces surfaces(shapes);
    intersectShapes(shapes, surfaces, features);
    drawEdges(*result, surfaces, features, projector, direction, tolerance,
              include_faces ? &cell_boundaries : nullptr);
    if (include_faces)
      projectFaces(*result, surfaces, shapes, cell_boundaries, projector,
                   direction, tolerance);
    *output = {result->commands.data(), result->lines.data(),
               result->lines.size(),    result->faces.data(),
               result->faces.size(),    result.get()};
    result.release();
    return 0;
  } catch (const std::bad_alloc &) {
    return 2;
  } catch (const Standard_Failure &e) {
    std::snprintf(error, capacity, "%s",
                  e.GetMessageString() ? e.GetMessageString() : "OCCT failure");
  } catch (const std::exception &e) {
    std::snprintf(error, capacity, "%s", e.what());
  } catch (...) {
    std::snprintf(error, capacity, "unknown geometry failure");
  }
  return 1;
}
extern "C" void huak_space_release(HuakLinework *output) {
  delete static_cast<huak::space::Result *>(output->owner);
  *output = {};
}
