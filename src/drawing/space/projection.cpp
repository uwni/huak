// The C table: models, their faces, and views of them. Each entry runs one
// OCCT operation over a batch and reports what OCCT returns; what to ask and
// what to make of the answers is Huak's.
#include "view.hxx"

namespace huak::space::entry {
void copy(const gp_XYZ &from, double *to) {
  to[0] = from.X();
  to[1] = from.Y();
  to[2] = from.Z();
}

const TopoDS_Shape &shapeOf(const HuakModel *model, size_t source) {
  require(model, "model");
  return element(model->shapes, source, "shape");
}

const TopoDS_Face &faceOf(const HuakModel *model, size_t source, size_t face) {
  shapeOf(model, source);
  const auto &faces = model->faces[source];
  if (face >= static_cast<size_t>(faces.Extent()))
    throw OutOfRange("face index out of range");
  return TopoDS::Face(faces(static_cast<int>(face) + 1));
}

namespace {
// Wraps a periodic parameter into [lo, hi] when a whole-period shift lands
// there, leaving values already in [lo, hi] (or genuinely outside a partial
// periodic face) untouched.
double wrapPeriodic(double value, double lo, double hi, double period) {
  if (!(period > 0))
    return value;
  if (value < lo) {
    const double shifted = value + std::ceil((lo - value) / period) * period;
    if (shifted <= hi + Precision::PConfusion())
      return std::min(shifted, hi);
  } else if (value > hi) {
    const double shifted = value - std::ceil((value - hi) / period) * period;
    if (shifted >= lo - Precision::PConfusion())
      return std::max(shifted, lo);
  }
  return value;
}

// Where d/du x d/dv vanishes, as at a cone's apex or a sphere's pole, the
// limit of the normal coming from inside the face's parameters, as OCCT's
// CSLib finds it from the first derivatives of d/du x d/dv that do not
// vanish, up to the third; false where they give none.
bool limitNormal(const Handle(Geom_Surface) & surface, const TopoDS_Face &face,
                 const gp_Pnt2d &uv, gp_Dir &normal) {
  constexpr int order = 3;
  try {
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    const double u = surface->IsUPeriodic() ? wrapPeriodic(uv.X(), u0, u1, surface->UPeriod()) : uv.X();
    const double v = surface->IsVPeriodic() ? wrapPeriodic(uv.Y(), v0, v1, surface->VPeriod()) : uv.Y();
    NCollection_Array2<gp_Vec> derivatives(0, order + 1, 0, order + 1);
    derivatives.Init(gp_Vec());
    for (int i = 0; i <= order + 1; ++i)
      for (int j = 0; i + j <= order + 1; ++j)
        if (i + j > 0)
          derivatives(i, j) = surface->DN(u, v, i, j);
    NCollection_Array2<gp_Vec> normals(0, order, 0, order);
    normals.Init(gp_Vec());
    for (int i = 0; i <= order; ++i)
      for (int j = 0; i + j <= order; ++j)
        normals(i, j) = CSLib::DNNUV(i, j, derivatives);
    CSLib_NormalStatus status;
    int orderU = 0, orderV = 0;
    CSLib::Normal(order, normals, Precision::Confusion(), u, v, u0, u1, v0, v1, status, normal, orderU, orderV);
    return status == CSLib_Defined;
  } catch (const Standard_Failure &) {
    return false;
  }
}
} // namespace

// The unit normal of a face, whose surface is given, as oriented in its
// shape: from the first and second derivatives, or where those give none,
// their limit (`limitNormal`); false where neither does.
bool normalOf(const Handle(Geom_Surface) & surface, const TopoDS_Face &face,
              const gp_Pnt2d &uv, gp_Dir &normal) {
  if (GeomLib::NormEstim(surface, uv, Precision::Confusion(), normal) >= 2 &&
      !limitNormal(surface, face, uv, normal))
    return false;
  if (face.Orientation() == TopAbs_REVERSED)
    normal.Reverse();
  return true;
}
} // namespace huak::space::entry

namespace {
int build(const HuakModelShape *input, size_t node_count, const size_t *roots,
          size_t count, double tolerance, HuakModel **out, char *error,
          size_t capacity) {
  return guarded(error, capacity, [&] {
    require(out, "out");
    *out = nullptr;
    requireArray(input, node_count, "nodes");
    requireArray(roots, count, "roots");
    auto model = std::make_unique<HuakModel>();
    model->tolerance = tolerance;
    std::vector<TopoDS_Shape> nodes;
    nodes.reserve(node_count);
    for (size_t i = 0; i < node_count; ++i)
      nodes.push_back(buildShape(input[i], nodes, tolerance));
    for (size_t i = 0; i < count; ++i)
      model->shapes.push_back(nodes.at(roots[i]));
    model->faces.resize(count);
    model->probes.resize(count);
    for (size_t i = 0; i < count; ++i) {
      TopExp::MapShapes(model->shapes[i], TopAbs_FACE, model->faces[i]);
      if (model->faces[i].IsEmpty())
        continue;
      model->probes[i] = std::make_unique<IntCurvesFace_ShapeIntersector>();
      model->probes[i]->Load(model->shapes[i], Precision::Confusion());
    }
    *out = model.release();
  });
}

void releaseModel(HuakModel *model) { delete model; }

int shape(const HuakModel *model, size_t source, HuakShape *out, char *error,
          size_t capacity) {
  return guarded(error, capacity, [&] {
    require(out, "out");
    Bnd_Box box;
    BRepBndLib::Add(shapeOf(model, source), box, false);
    HuakShape result{};
    result.faces = static_cast<size_t>(model->faces[source].Extent());
    result.empty = box.IsVoid();
    if (!result.empty)
      box.Get(result.box[0], result.box[1], result.box[2], result.box[3],
              result.box[4], result.box[5]);
    *out = result;
  });
}

int same(const HuakModel *model, size_t first, size_t second, int *out,
         char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(out, "out");
    *out = shapeOf(model, first).IsSame(shapeOf(model, second));
  });
}

int face(const HuakModel *model, size_t source, size_t index, HuakFace *out,
         char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(out, "out");
    const auto &f = faceOf(model, source, index);
    const BRepAdaptor_Surface surface(f);
    HuakFace result{};
    switch (surface.GetType()) {
    case GeomAbs_Plane:
      result.kind = HUAK_PLANAR;
      break;
    case GeomAbs_Cylinder: {
      result.kind = HUAK_CYLINDRICAL;
      const gp_Ax3 frame = surface.Cylinder().Position();
      copy(frame.XDirection().XYZ(), result.axis_x);
      copy(frame.YDirection().XYZ(), result.axis_y);
      break;
    }
    case GeomAbs_Cone: {
      result.kind = HUAK_CONICAL;
      const gp_Cone cone = surface.Cone();
      result.semi_angle = cone.SemiAngle();
      // Any u names the apex; only its v matters.
      double u = 0;
      ElSLib::Parameters(cone, cone.Apex(), u, result.apex_v);
      break;
    }
    case GeomAbs_Sphere:
      result.kind = HUAK_SPHERICAL;
      break;
    case GeomAbs_Torus:
      result.kind = HUAK_TOROIDAL;
      break;
    default:
      result.kind = HUAK_FREEFORM;
    }
    BRepTools::UVBounds(f, result.u0, result.u1, result.v0, result.v1);
    result.u_period = surface.IsUPeriodic() ? surface.UPeriod() : 0;
    result.v_period = surface.IsVPeriodic() ? surface.VPeriod() : 0;
    *out = result;
  });
}

int normalTurns(const HuakModel *model, size_t source, size_t index,
                const HuakUV *uv, size_t count, HuakNormalTurn *out,
                char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    requireArray(uv, count, "uv");
    requireArray(out, count, "out");
    const auto &f = faceOf(model, source, index);
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(f);
    const double sign = f.Orientation() == TopAbs_REVERSED ? -1 : 1;
    NCollection_Array2<gp_Vec> derivatives(0, 2, 0, 2), normals(0, 1, 0, 1);
    for (size_t k = 0; k < count; ++k) {
      HuakNormalTurn result{};
      const gp_Pnt2d at(uv[k].u, uv[k].v);
      gp_Dir normal;
      if (GeomLib::NormEstim(surface, at, Precision::Confusion(), normal) == 0) {
        gp_Pnt point;
        gp_Vec d1u, d1v, d2u, d2v, d2uv;
        surface->D2(at.X(), at.Y(), point, d1u, d1v, d2u, d2v, d2uv);
        derivatives.Init(gp_Vec());
        derivatives(1, 0) = d1u;
        derivatives(0, 1) = d1v;
        derivatives(2, 0) = d2u;
        derivatives(1, 1) = d2uv;
        derivatives(0, 2) = d2v;
        for (int i = 0; i <= 1; ++i)
          for (int j = 0; j + i <= 1; ++j)
            normals(i, j) = CSLib::DNNUV(i, j, derivatives);
        copy(CSLib::DNNormal(1, 0, normals).XYZ() * sign, result.du);
        copy(CSLib::DNNormal(0, 1, normals).XYZ() * sign, result.dv);
        result.defined = 1;
      }
      out[k] = result;
    }
  });
}

// n(uv(s)) . direction - value along a segment of a face's parameters.
class Facing : public math_Function {
public:
  Facing(const Handle(Geom_Surface) & surface, const TopoDS_Face &face,
         gp_XY from, gp_XY to, gp_Dir direction, double value)
      : surface_(surface), face_(face), from_(from), to_(to),
        direction_(direction), value_(value) {}
  bool Value(const double s, double &f) override {
    gp_Dir normal;
    if (!normalOf(surface_, face_, gp_Pnt2d(from_ + (to_ - from_) * s), normal))
      return false;
    f = normal.Dot(direction_) - value_;
    return true;
  }

private:
  Handle(Geom_Surface) surface_;
  TopoDS_Face face_;
  gp_XY from_, to_;
  gp_Dir direction_;
  double value_;
};

int roots(const HuakModel *model, size_t source, size_t index,
          const HuakSegment *segments, size_t count, const double direction[3],
          double value, double tolerance, double *out, char *error,
          size_t capacity) {
  return guarded(error, capacity, [&] {
    requireArray(segments, count, "segments");
    require(direction, "direction");
    requireArray(out, count, "out");
    const auto &f = faceOf(model, source, index);
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(f);
    const gp_Dir along(direction[0], direction[1], direction[2]);
    for (size_t k = 0; k < count; ++k) {
      Facing facing(surface, f, gp_XY(segments[k].from.u, segments[k].from.v),
                    gp_XY(segments[k].to.u, segments[k].to.v), along, value);
      double low, high;
      out[k] = std::numeric_limits<double>::quiet_NaN();
      if (!facing.Value(0, low) || !facing.Value(1, high) || low * high > 0)
        continue;
      math_BracketedRoot root(facing, 0, 1, tolerance);
      if (root.IsDone())
        out[k] = root.Root();
    }
  });
}

int view(HuakModel *model, const double eye[3], const double x[3], double focus,
         HuakView **out, HuakFrame *frame, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(out, "out");
    *out = nullptr;
    require(model, "model");
    require(eye, "eye");
    require(x, "x");
    require(frame, "frame");
    const gp_Ax2 axes(gp::Origin(), gp_Dir(eye[0], eye[1], eye[2]),
                      gp_Dir(x[0], x[1], x[2]));
    auto result = std::make_unique<HuakView>(*model, axes, focus);
    HuakFrame f{};
    copy(axes.XDirection().XYZ(), f.x);
    copy(axes.YDirection().XYZ(), f.y);
    copy(axes.Direction().XYZ(), f.eye);
    f.focus = focus;
    *frame = f;
    *out = result.release();
  });
}

void releaseView(HuakView *view) { delete view; }

int samples(HuakView *view, size_t source, size_t index, const HuakUV *uv,
            size_t count, HuakSample *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(uv, count, "uv");
    requireArray(out, count, "out");
    const auto &f = faceOf(&view->model, source, index);
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(f);
    for (size_t k = 0; k < count; ++k) {
      const gp_Pnt2d at(uv[k].u, uv[k].v);
      HuakSample result{};
      result.look = view->look(surface->Value(at.X(), at.Y()));
      gp_Dir normal;
      if (normalOf(surface, f, at, normal)) {
        copy(normal.XYZ(), result.normal);
        result.defined = 1;
      }
      out[k] = result;
    }
  });
}

int sightings(HuakView *view, size_t source, size_t index, const HuakXY *points,
              size_t count, HuakSightings *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(points, count, "points");
    require(out, "out");
    faceOf(&view->model, source, index);
    auto &sights = view->sights();
    auto &offsets = view->result(view->indices);
    auto &found = view->result(view->sightings);
    offsets.push_back(0);
    std::vector<huak::space::Sight> met;
    for (size_t k = 0; k < count; ++k) {
      sights.meet(source, index, gp_Pnt2d(points[k].x, points[k].y), met);
      for (const auto &sight : met)
        found.push_back({view->depth(sight.point), sight.u, sight.v});
      offsets.push_back(found.size());
    }
    *out = {offsets.data(), found.data(), count};
  });
}

int rays(HuakView *view, const HuakXY *points, size_t count, HuakShapeHits *out,
         char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(points, count, "points");
    require(out, "out");
    auto &sights = view->sights();
    auto &offsets = view->result(view->indices);
    auto &found = view->result(view->hits);
    offsets.push_back(0);
    std::vector<huak::space::Sight> met;
    for (size_t k = 0; k < count; ++k) {
      sights.meet(gp_Pnt2d(points[k].x, points[k].y), met);
      for (const auto &sight : met)
        found.push_back({sight.source, sight.face, view->depth(sight.point),
                         sight.u, sight.v});
      offsets.push_back(found.size());
    }
    *out = {offsets.data(), found.data(), count};
  });
}
} // namespace

extern "C" __attribute__((visibility("default")))
const HuakProjectionV7 *huak_space_api_v7() {
  static const HuakProjectionV7 api{
      HUAK_SPACE_ABI_VERSION, sizeof(HuakProjectionV7),
      build,       releaseModel, shape,     same,        face,
      normalTurns, roots,        view,      releaseView, samples,
      sightings,   rays,         curves,    edges,       rims,
      sections,    project,      pierce,    approximate, contours,
      arrange,     cells,        fill,      regions};
  return &api;
}
