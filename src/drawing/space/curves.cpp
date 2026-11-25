// Projected curves: the image of an edge in the projection plane, its planar
// curve, and its conversion to Huak's cubic path commands.
#include "space.hxx"
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <Bnd_Box.hxx>
#include <cmath>
#include <BRepLib.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Tool.hxx>
#include <GeomAPI.hxx>
#include <GeomConvert.hxx>
#include <GeomConvert_ApproxCurve.hxx>
#include <GeomConvert_BSplineCurveToBezierCurve.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_Line.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Wire.hxx>
#include <algorithm>
#include <gp_Pln.hxx>
#include <stdexcept>

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

// A perspective projector maps (x, y, z) to (x, y) / w with w = 1 - z / f:
// its derivative is (1 / w) [I | (x, y) / (f w)], whose norm is
// sqrt(1 + rho^2 / (f w)^2) / w with rho = |(x, y)|. Both factors grow with
// z and rho, so their values at the box's farthest-forward and widest
// corners bound it over the edge.
double magnification(const TopoDS_Edge &edge,
                     const HLRAlgo_Projector &projector) {
  if (!projector.Perspective())
    return 1;
  Bnd_Box box;
  BRepBndLib::Add(edge, box);
  if (box.IsVoid())
    return 1;
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  double front = -RealLast(), wide = 0;
  for (int i = 0; i < 8; ++i) {
    gp_Pnt p(i & 1 ? x1 : x0, i & 2 ? y1 : y0, i & 4 ? z1 : z0);
    projector.Transform(p);
    front = std::max(front, p.Z());
    wide = std::max(wide, std::hypot(p.X(), p.Y()));
  }
  const double f = projector.Focus();
  const double w = 1.0 - front / f;
  if (w <= 0)
    throw std::domain_error("shape crosses the camera eye plane");
  const double spread = wide / (f * w);
  return std::sqrt(1 + spread * spread) / w;
}

Handle(Geom2d_Curve) inPlane(const TopoDS_Edge &edge) {
  double a, b;
  auto curve = BRep_Tool::Curve(edge, a, b);
  return GeomAPI::To2d(new Geom_TrimmedCurve(curve, a, b), gp_Pln(gp::XOY()));
}

void writeEdge(std::vector<HuakPathCommand> &commands, const TopoDS_Edge &edge,
               double tolerance, bool move) {
  double first, last;
  const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
  if (curve.IsNull())
    throw std::runtime_error("missing projected curve");
  Handle(Geom_TrimmedCurve) portion = new Geom_TrimmedCurve(curve, first, last);
  if (edge.Orientation() == TopAbs_REVERSED)
    portion->Reverse();
  if (move)
    commands.push_back({HUAK_MOVE, {xy(portion->StartPoint())}});
  if (curve->IsKind(STANDARD_TYPE(Geom_Line))) {
    commands.push_back({HUAK_LINE, {xy(portion->EndPoint())}});
    return;
  }
  GeomConvert_ApproxCurve approx(portion, tolerance, GeomAbs_C0, 1024, 3);
  if (!approx.IsDone() || approx.MaxError() > tolerance)
    throw std::runtime_error("projected curve exceeded tolerance");
  GeomConvert_BSplineCurveToBezierCurve split(approx.Curve());
  for (int i = 1; i <= split.NbArcs(); ++i) {
    auto arc = split.Arc(i);
    arc->Increase(3);
    commands.push_back(
        {HUAK_BEZIER, {xy(arc->Pole(2)), xy(arc->Pole(3)), xy(arc->Pole(4))}});
  }
}

void writeFace(std::vector<HuakPathCommand> &commands, TopoDS_Face face,
               double tolerance) {
  face.Orientation(TopAbs_FORWARD);
  for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
    const auto start = commands.size();
    for (BRepTools_WireExplorer e(TopoDS::Wire(w.Current()), face); e.More();
         e.Next())
      writeEdge(commands, e.Current(), tolerance, commands.size() == start);
    if (commands.size() > start) {
      // Both ends of a wire share one vertex. Independent evaluations of
      // the same point must not create an extra microscopic closing edge.
      auto &last = commands.back();
      last.p[last.op == HUAK_BEZIER ? 2 : 0] = commands[start].p[0];
      commands.push_back({HUAK_CLOSE, {}});
    }
  }
}
} // namespace huak::space
