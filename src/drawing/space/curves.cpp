// A drawn curve can lie exactly on an occluding surface. Split in image space
// and compare depth against the original faces, retaining the curve parameter.
#include "result.hxx"
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRep_Tool.hxx>
#include <Geom2dAPI_InterCurveCurve.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <GeomAPI.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomConvert.hxx>
#include <Geom_Line.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <algorithm>
#include <gp_Pln.hxx>
#include <stdexcept>

namespace huak::space {
static Handle(Geom2d_Curve) inPlane(const TopoDS_Edge &edge) {
  double a, b;
  auto curve = BRep_Tool::Curve(edge, a, b);
  return GeomAPI::To2d(new Geom_TrimmedCurve(curve, a, b), gp_Pln(gp::XOY()));
}

void drawEdges(Result &out, Surfaces &surfaces,
               const std::vector<Feature> &features,
               const HLRAlgo_Projector &projector, const gp_Dir &toward_eye,
               double tolerance, std::vector<TopoDS_Edge> *cell_boundaries) {
  const bool layered = cell_boundaries != nullptr;
  struct Border {
    size_t feature;
    Handle(Geom2d_Curve) curve;
  };
  std::vector<Border> borders;
  std::vector<TopoDS_Edge> images(features.size());
  for (size_t k = 0; k < features.size(); ++k) {
    const auto &f = features[k];
    if (!f.own_visible.has_value())
      continue;
    images[k] = projected(f.edge, projector, tolerance);
    if (images[k].IsNull())
      continue;
    if (layered || *f.own_visible)
      borders.push_back({k, inPlane(images[k])});
    if (cell_boundaries && f.kind == HUAK_OUTLINE)
      cell_boundaries->push_back(images[k]);
  }
  for (size_t index = 0; index < features.size(); ++index) {
    const auto &f = features[index];
    const size_t i = f.source;
    const auto &edge = f.edge;
    if (f.own_visible.has_value()) {
      if (images[index].IsNull())
        continue;
      if ((!layered && !*f.own_visible) ||
          (surfaces.count == 1 && (*f.own_visible || !layered))) {
        const auto offset = out.commands.size();
        writeEdge(out, images[index], tolerance);
        out.lines.push_back({i, offset, out.commands.size() - offset,
                             *f.own_visible ? 0u : 1u, f.kind, f.other_source});
        continue;
      }
    }
    double a, b;
    auto spatial = BRep_Tool::Curve(edge, a, b);
    auto spline =
        GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(spatial, a, b));
    // A line's projected arclength is not its parameter in perspective.
    // Projecting its degree-one spline retains the perspective weights.
    auto image =
        projected(BRepBuilderAPI_MakeEdge(spline), projector, tolerance);
    if (image.IsNull())
      continue;
    if (cell_boundaries && f.kind == HUAK_INTERSECTION)
      cell_boundaries->push_back(image);
    auto curve = inPlane(image);
    double start = curve->FirstParameter(), stop = curve->LastParameter();
    std::vector<double> cuts{start, stop};
    for (const auto &border : borders) {
      if (border.feature == index || (features[border.feature].source == i &&
                                      f.own_visible.value_or(false)))
        continue;
      Geom2dAPI_InterCurveCurve inter(curve, border.curve,
                                      Precision::Confusion());
      auto &hits = inter.Intersector();
      if (!hits.IsDone())
        throw std::runtime_error("projected curve intersection failed");
      for (int k = 1; k <= hits.NbPoints(); ++k)
        cuts.push_back(hits.Point(k).ParamOnFirst());
      for (int k = 1; k <= hits.NbSegments(); ++k) {
        auto &s = hits.Segment(k);
        if (s.HasFirstPoint())
          cuts.push_back(s.FirstPoint().ParamOnFirst());
        if (s.HasLastPoint())
          cuts.push_back(s.LastPoint().ParamOnFirst());
      }
    }
    Handle(Geom2d_Curve) uv;
    Handle(Geom_Surface) surface;
    TopLoc_Location location;
    double u0, u1;
    if (f.kind == HUAK_CURVE)
      BRep_Tool::CurveOnSurface(edge, uv, surface, location, u0, u1);
    for (size_t owner = 0; owner < surfaces.probes.size(); ++owner) {
      auto &probe = surfaces.probes[owner];
      if (!probe || owner == i ||
          static_cast<ptrdiff_t>(owner) == f.other_source)
        continue;
      probe->Perform(new GeomAdaptor_Curve(spline), spline->FirstParameter(),
                     spline->LastParameter());
      if (!probe->IsDone())
        throw std::runtime_error("space curve intersection failed");
      for (int k = 1; k <= probe->NbPnt(); ++k)
        cuts.push_back(probe->WParameter(k));
    }
    std::sort(cuts.begin(), cuts.end());
    bool has_interval = false;
    size_t previous = 0;
    double run = start;
    auto emit = [&](double end, size_t covering) {
      size_t offset = out.commands.size();
      if (spatial->IsKind(STANDARD_TYPE(Geom_Line))) {
        auto p = curve->Value(run), q = curve->Value(end);
        if (p.Distance(q) <= Precision::Confusion())
          return;
        out.commands.push_back({HUAK_MOVE, {{p.X(), p.Y()}}});
        out.commands.push_back({HUAK_LINE, {{q.X(), q.Y()}}});
      } else {
        double f, l;
        auto projected_curve = BRep_Tool::Curve(image, f, l);
        writeEdge(out, BRepBuilderAPI_MakeEdge(projected_curve, run, end),
                  tolerance);
      }
      out.lines.push_back({i, offset, out.commands.size() - offset, covering,
                           f.kind, f.other_source});
    };
    for (size_t k = 1; k < cuts.size(); ++k) {
      double lo = std::max(start, cuts[k - 1]), hi = std::min(stop, cuts[k]);
      if (hi - lo <= Precision::PConfusion())
        continue;
      double mid = (lo + hi) * 0.5;
      auto p = spline->Value(mid);
      if (!uv.IsNull()) {
        auto param = uv->Value(mid);
        p = surface->Value(param.X(), param.Y())
                .Transformed(location.Transformation());
      }
      gp_Pnt2d screen;
      projector.Project(p, screen);
      auto ray = projector.Shoot(screen.X(), screen.Y());
      const double depth = p.XYZ().Dot(toward_eye.XYZ());
      size_t covering = 0;
      for (const Hit &hit : surfaces.along(ray, toward_eye)) {
        if (f.own_visible.value_or(false) && hit.source == i)
          continue;
        const double delta = hit.depth - depth;
        const bool tied_face = f.own_visible.has_value() && hit.source < i &&
                               std::abs(delta) <= Precision::Confusion();
        const bool section_owner =
            f.kind == HUAK_INTERSECTION &&
            (hit.source == i ||
             static_cast<ptrdiff_t>(hit.source) == f.other_source);
        if (delta > (section_owner ? BRep_Tool::Tolerance(edge)
                                   : Precision::Confusion()) ||
            tied_face) {
          ++covering;
          if (!layered)
            break;
        }
      }
      if (has_interval && covering != previous) {
        emit(lo, previous);
        run = lo;
      }
      previous = covering;
      has_interval = true;
    }
    if (has_interval)
      emit(stop, previous);
  }
}
} // namespace huak::space
