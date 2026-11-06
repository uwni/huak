#include "lighting.hxx"
#include <Adaptor2d_Curve2d.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepGProp.hxx>
#include <BRepTopAdaptor_MapOfShapeTool.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Contap_Contour.hxx>
#include <GProp_GProps.hxx>
#include <GeomLib.hxx>
#include <HLRTopoBRep_DSFiller.hxx>
#include <HLRTopoBRep_Data.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <algorithm>
#include <cmath>
#include <gp_Pln.hxx>
#include <stdexcept>
namespace huak::space {
// A draft contour is the locus of a constant angle between the surface
// normal and a fixed direction. OCCT trims it against the actual face.
static void projectContour(const TopoDS_Face &face, gp_Dir direction,
                                double width,
                                const HLRAlgo_Projector &projector,
                                double tolerance,
                                TopTools_ListOfShape &boundaries) {
  if (face.Orientation() == TopAbs_REVERSED)
    direction.Reverse();
  Contap_Contour contour;
  contour.Init(gp_Vec(direction), width - M_PI / 2);
  HLRTopoBRep_Data data;
  BRepTopAdaptor_MapOfShapeTool tools;
  HLRTopoBRep_DSFiller::Insert(face, contour, data, tools, 0);
  if (!contour.IsDone())
    throw std::runtime_error("cannot trace lighting contour");
  auto append = [&](const TopoDS_Edge &edge) {
    auto curve = projected(edge, projector, tolerance);
    if (!curve.IsNull())
      boundaries.Append(curve);
  };
  if (data.FaceHasIntL(face))
    for (const auto &edge : data.FaceIntL(face))
      append(TopoDS::Edge(edge));
  // The HLR data structure stores intervals between vertices. A complete
  // analytic contour wholly inside its face can have no trimming vertices.
  for (int i = 1; i <= contour.NbLines(); ++i) {
    const auto &line = contour.Line(i);
    if (!line.NbVertex() && line.TypeContour() == Contap_Circle)
      append(BRepBuilderAPI_MakeEdge(line.Circle()));
  }
}

Lighting::Lighting(const HuakLight &light, const Surfaces &surfaces,
                   const HLRAlgo_Projector &projector, const gp_Dir &toward_eye,
                   double tolerance, TopTools_ListOfShape &boundaries)
    : light_(light), sun_(light.direction[0], light.direction[1], light.direction[2]),
      eye_(toward_eye) {
  const gp_Vec bisector = gp_Vec(sun_) + gp_Vec(toward_eye);
  if (light.spot_angle > 0 && bisector.Magnitude() > Precision::Angular())
    half.emplace(bisector);
  cutoff = std::cos(light.spot_angle);
  faces_.reserve(surfaces.faces.size());
  for (const auto &faces : surfaces.faces) {
    auto &rows = faces_.emplace_back(faces.Extent());
    for (int i = 1; i <= faces.Extent(); ++i) {
      auto &paint = rows[i - 1];
      const auto &face = TopoDS::Face(faces(i));
      BRepAdaptor_Surface surface(face);
      paint.planar = surface.GetType() == GeomAbs_Plane;
      if (paint.planar)
        continue;
      for (size_t level = 0; level < light.isophote_count; ++level)
        projectContour(face, sun_, std::acos(light.isophotes[level]), projector,
                       tolerance, boundaries);
      if (half)
        projectContour(face, *half, light.spot_angle, projector, tolerance,
                            boundaries);
    }
  }
}
Lighting::Sample Lighting::classify(const Hit &hit, const TopoDS_Face &face,
                                    const TopoDS_Face &cell) {
  auto &paint = faces_[hit.source][hit.face];
  gp_Dir normal;
  if (GeomLib::NormEstim(BRep_Tool::Surface(face), hit.uv,
                         Precision::Confusion(), normal) >= 2)
    throw std::runtime_error("undefined surface normal at lighting sample");
  if (face.Orientation() == TopAbs_REVERSED)
    normal.Reverse();
  const double facing = normal.Dot(sun_);
  const bool gleam = half && facing > 0 && normal.Dot(eye_) > 0 &&
                     normal.Dot(*half) >= cutoff;
  if (gleam && !paint.planar)
    paint.lit_cells.Add(cell);
  if (paint.planar || facing <= 0)
    return {std::max(0., facing), gleam};
  const auto begin = light_.isophotes, end = begin + light_.isophote_count;
  const auto next = std::upper_bound(begin, end, facing);
  const double low = *(next - 1), high = next == end ? 1. : *next;
  return {(low + high) / 2, gleam};
}
void Lighting::fitSpots(Result &out) {
  BRep_Builder builder;
  // Fit one elliptical falloff to each connected gleam before occlusion.
  // For an ellipse the second moments give its exact semiaxes and direction.
  for (auto &source : faces_)
    for (auto &paint : source) {
      if (paint.lit_cells.IsEmpty())
        continue;
      TopoDS_Compound lit;
      builder.MakeCompound(lit);
      for (int i = 1; i <= paint.lit_cells.Extent(); ++i)
        builder.Add(lit, paint.lit_cells(i));
      ShapeUpgrade_UnifySameDomain merge(lit, true, true);
      merge.Build();
      paint.start = out.lobes.size();
      for (TopExp_Explorer it(merge.Shape(), TopAbs_FACE); it.More();
           it.Next()) {
        GProp_GProps props;
        BRepGProp::SurfaceProperties(it.Current(), props, 1e-7);
        const double area = props.Mass();
        if (area <= 0)
          throw std::runtime_error("invalid highlight area");
        const gp_Mat m = props.MatrixOfInertia();
        const double xx = m(2, 2) / area, yy = m(1, 1) / area,
                     xy = -m(1, 2) / area;
        const double d = std::hypot(xx - yy, 2 * xy);
        const double a = std::sqrt(2 * (xx + yy + d));
        const double b = std::sqrt(2 * std::max(0., xx + yy - d));
        if (b == 0)
          continue;
        const double theta = .5 * std::atan2(2 * xy, xx - yy);
        const double c = std::cos(theta), s = std::sin(theta);
        const auto p = props.CentreOfMass();
        out.lobes.push_back({{p.X(), p.Y()}, {a * c, a * s}, {-b * s, b * c}});
      }
      paint.count = out.lobes.size() - paint.start;
    }
}
} // namespace huak::space
