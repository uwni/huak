// The C table: models, their faces, and views of them. Each entry runs one
// OCCT operation over a batch and reports what OCCT returns; what to ask and
// what to make of the answers is Huak's.
#include "space.hxx"
#include <BOPTools_AlgoTools3D.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepGProp.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <CSLib.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>
#include <Geom2dAPI_InterCurveCurve.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomConvert.hxx>
#include <GeomLib.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Line.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <IntCurvesFace_Intersector.hxx>
#include <IntTools_Context.hxx>
#include <NCollection_Array2.hxx>
#include <NCollection_IndexedDataMap.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <cmath>
#include <cstdio>
#include <deque>
#include <gp_Pln.hxx>
#include <limits>
#include <math_BracketedRoot.hxx>
#include <math_Function.hxx>
#include <stdexcept>
#include <string>

using namespace huak::space;

namespace {
// A required pointer was null, or a count disagreed with its array.
struct InvalidArgument : std::invalid_argument {
  using std::invalid_argument::invalid_argument;
};
// An index named nothing.
struct OutOfRange : std::out_of_range {
  using std::out_of_range::out_of_range;
};

template <class T> void require(const T *pointer, const char *name) {
  if (!pointer)
    throw InvalidArgument(std::string(name) + " must not be null");
}
template <class T>
void requireArray(const T *pointer, size_t count, const char *name) {
  if (count && !pointer)
    throw InvalidArgument(std::string(name) + " must not be null for a nonzero count");
}

template <class T>
const T &element(const std::vector<T> &items, size_t index, const char *what) {
  if (index >= items.size())
    throw OutOfRange(std::string(what) + " index out of range");
  return items[index];
}
} // namespace

// Results stay where they are until the view is released: a deque does not
// move its elements, nor a vector its storage once filled.
struct HuakView {
  HuakView(HuakModel &model, const gp_Ax2 &axes, double focus)
      : model(model),
        projector(focus == 0 ? HLRAlgo_Projector(axes)
                             : HLRAlgo_Projector(axes, focus)),
        context(new IntTools_Context()), borders(model.shapes.size()) {}

  HuakModel &model;
  HLRAlgo_Projector projector;
  Handle(IntTools_Context) context;
  std::vector<TopoDS_Edge> curves, images;
  std::vector<Handle(Geom_BSplineCurve)> splines;
  std::vector<Handle(Geom2d_Curve)> planes;
  std::vector<TopoDS_Face> regions;
  // For each shape, the pieces of its tracked images.
  std::vector<ShapeSet> borders;
  std::deque<std::vector<size_t>> indices;
  std::deque<std::vector<double>> numbers;
  std::deque<std::vector<HuakPathCommand>> paths;
  std::deque<std::vector<HuakSilhouette>> silhouettes;
  std::deque<std::vector<HuakEdge>> edges;
  std::deque<std::vector<HuakSighting>> sightings;
  std::deque<std::vector<HuakShapeHit>> hits;

  template <class T> std::vector<T> &result(std::deque<std::vector<T>> &store) {
    return store.emplace_back();
  }
  size_t addCurve(const TopoDS_Edge &edge) {
    curves.push_back(edge);
    splines.emplace_back();
    return curves.size() - 1;
  }
  size_t addImage(const TopoDS_Edge &edge) {
    images.push_back(edge);
    planes.emplace_back();
    return images.size() - 1;
  }
  size_t addRegion(const TopoDS_Face &face) {
    regions.push_back(face);
    return regions.size() - 1;
  }
  const TopoDS_Edge &curve(size_t index) const {
    return element(curves, index, "curve");
  }
  const TopoDS_Edge &image(size_t index) const {
    return element(images, index, "image");
  }
  const TopoDS_Face &region(size_t index) const {
    return element(regions, index, "region");
  }
  // The curve as a spline over its edge's range.
  const Handle(Geom_BSplineCurve) & spline(size_t index) {
    curve(index);
    auto &spline = splines[index];
    if (spline.IsNull()) {
      double a, b;
      const auto curve = BRep_Tool::Curve(curves[index], a, b);
      if (curve.IsNull())
        throw std::runtime_error("missing source curve");
      spline =
          GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(curve, a, b));
    }
    return spline;
  }
  const Handle(Geom2d_Curve) & plane(size_t index) {
    image(index);
    auto &plane = planes[index];
    if (plane.IsNull())
      plane = inPlane(images[index]);
    return plane;
  }
  // The screen position of a point and its depth toward the viewer.
  HuakLook look(const gp_Pnt &point) const {
    gp_Pnt2d screen;
    projector.Project(point, screen);
    gp_Pnt local = point;
    projector.Transform(local);
    return {screen.X(), screen.Y(), local.Z()};
  }
  double depth(const gp_Pnt &point) const {
    gp_Pnt local = point;
    projector.Transform(local);
    return local.Z();
  }
};

namespace {
// Runs `body`, reporting C++ failures through the table's status codes.
template <class Body> int guarded(char *error, size_t capacity, Body &&body) {
  const auto report = [&](const char *message) {
    if (error && capacity)
      std::snprintf(error, capacity, "%s", message);
  };
  try {
    body();
    return HUAK_SPACE_OK;
  } catch (const std::bad_alloc &) {
    report("out of memory");
    return HUAK_SPACE_OUT_OF_MEMORY;
  } catch (const InvalidArgument &e) {
    report(e.what());
    return HUAK_SPACE_INVALID_ARGUMENT;
  } catch (const OutOfRange &e) {
    report(e.what());
    return HUAK_SPACE_OUT_OF_RANGE;
  } catch (const Standard_Failure &e) {
    report(e.what() ? e.what() : "OCCT failure");
  } catch (const std::exception &e) {
    report(e.what());
  } catch (...) {
    report("unknown geometry failure");
  }
  return HUAK_SPACE_FAILED;
}

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

// The unit normal of a face as oriented in its shape; false where undefined.
bool normalOf(const Handle(Geom_Surface) & surface, bool reversed,
              const gp_Pnt2d &uv, gp_Dir &normal) {
  if (GeomLib::NormEstim(surface, uv, Precision::Confusion(), normal) >= 2)
    return false;
  if (reversed)
    normal.Reverse();
  return true;
}

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
    case GeomAbs_Cone:
      result.kind = HUAK_CONICAL;
      result.semi_angle = surface.Cone().SemiAngle();
      break;
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
  Facing(const Handle(Geom_Surface) & surface, bool reversed, gp_XY from,
         gp_XY to, gp_Dir direction, double value)
      : surface_(surface), reversed_(reversed), from_(from), to_(to),
        direction_(direction), value_(value) {}
  bool Value(const double s, double &f) override {
    gp_Dir normal;
    if (!normalOf(surface_, reversed_, gp_Pnt2d(from_ + (to_ - from_) * s),
                  normal))
      return false;
    f = normal.Dot(direction_) - value_;
    return true;
  }

private:
  Handle(Geom_Surface) surface_;
  bool reversed_;
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
    const bool reversed = f.Orientation() == TopAbs_REVERSED;
    const gp_Dir along(direction[0], direction[1], direction[2]);
    for (size_t k = 0; k < count; ++k) {
      Facing facing(surface, reversed,
                    gp_XY(segments[k].from.u, segments[k].from.v),
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

int look(HuakView *view, const HuakXYZ *points, size_t count, HuakLook *out,
         char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(points, count, "points");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k)
      out[k] = view->look(
          gp_Pnt(points[k].xyz[0], points[k].xyz[1], points[k].xyz[2]));
  });
}

int samples(HuakView *view, size_t source, size_t index, const HuakUV *uv,
            size_t count, HuakSample *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(uv, count, "uv");
    requireArray(out, count, "out");
    const auto &f = faceOf(&view->model, source, index);
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(f);
    const bool reversed = f.Orientation() == TopAbs_REVERSED;
    for (size_t k = 0; k < count; ++k) {
      const gp_Pnt2d at(uv[k].u, uv[k].v);
      HuakSample result{};
      result.look = view->look(surface->Value(at.X(), at.Y()));
      gp_Dir normal;
      if (normalOf(surface, reversed, at, normal)) {
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
    IntCurvesFace_Intersector intersector(faceOf(&view->model, source, index),
                                          Precision::Confusion());
    auto &offsets = view->result(view->indices);
    auto &found = view->result(view->sightings);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      intersector.Perform(view->projector.Shoot(points[k].x, points[k].y),
                          -RealLast(), RealLast());
      if (!intersector.IsDone())
        throw std::runtime_error("surface intersection query failed");
      for (int i = 1; i <= intersector.NbPnt(); ++i)
        found.push_back({view->depth(intersector.Pnt(i)),
                         intersector.UParameter(i), intersector.VParameter(i)});
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
    auto &model = view->model;
    auto &offsets = view->result(view->indices);
    auto &found = view->result(view->hits);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      const gp_Lin ray = view->projector.Shoot(points[k].x, points[k].y);
      for (size_t i = 0; i < model.probes.size(); ++i) {
        if (!model.probes[i])
          continue;
        auto &probe = *model.probes[i];
        probe.Perform(ray, -RealLast(), RealLast());
        if (!probe.IsDone())
          throw std::runtime_error("surface visibility query failed");
        for (int j = 1; j <= probe.NbPnt(); ++j)
          found.push_back(
              {i,
               static_cast<size_t>(model.faces[i].FindIndex(probe.Face(j)) - 1),
               view->depth(probe.Pnt(j)), probe.UParameter(j),
               probe.VParameter(j)});
      }
      offsets.push_back(found.size());
    }
    *out = {offsets.data(), found.data(), count};
  });
}

int curves(HuakView *view, size_t source, HuakIndices *out, char *error,
           size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    auto &items = view->result(view->indices);
    for (TopExp_Explorer e(shapeOf(&view->model, source), TopAbs_EDGE); e.More();
         e.Next())
      items.push_back(view->addCurve(TopoDS::Edge(e.Current())));
    *out = {items.data(), items.size()};
  });
}

int edges(HuakView *view, size_t source, HuakEdges *out, char *error,
          size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    NCollection_IndexedDataMap<TopoDS_Shape, ShapeList, TopTools_ShapeMapHasher>
        adjacent;
    TopExp::MapShapesAndUniqueAncestors(shapeOf(&view->model, source),
                                        TopAbs_EDGE, TopAbs_FACE, adjacent);
    auto &items = view->result(view->edges);
    for (int i = 1; i <= adjacent.Extent(); ++i) {
      const auto &faces = adjacent.FindFromIndex(i);
      const auto &edge = TopoDS::Edge(adjacent.FindKey(i));
      const bool closed =
          faces.Extent() == 1 &&
          BRep_Tool::IsClosed(edge, TopoDS::Face(faces.First()));
      items.push_back({view->addCurve(edge),
                       static_cast<size_t>(faces.Extent()), closed});
    }
    *out = {items.data(), items.size()};
  });
}

int silhouettes(HuakView *view, size_t source, HuakSilhouettes *out,
                char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    const auto &shape = shapeOf(&view->model, source);
    Handle(HLRBRep_Algo) algo = new HLRBRep_Algo();
    algo->Projector(view->projector);
    algo->Add(shape);
    algo->Update();
    algo->Hide();
    HLRBRep_HLRToShape extract(algo);
    const HLRBRep_TypeOfResultingEdge kinds[] = {
        HLRBRep_Sharp, HLRBRep_OutLine, HLRBRep_Rg1Line, HLRBRep_RgNLine};
    auto &items = view->result(view->silhouettes);
    for (int kind = 0; kind < 4; ++kind)
      for (bool visible : {true, false}) {
        auto group = extract.CompoundOfEdges(shape, kinds[kind], visible, true);
        for (TopExp_Explorer e(group, TopAbs_EDGE); e.More(); e.Next())
          items.push_back({view->addCurve(TopoDS::Edge(e.Current())), kind,
                           visible});
      }
    *out = {items.data(), items.size()};
  });
}

int sections(HuakView *view, size_t first, size_t second, HuakIndices *out,
             char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    BRepAlgoAPI_Section section(shapeOf(&view->model, first),
                                shapeOf(&view->model, second), false);
    section.Approximation(true);
    section.SetNonDestructive(true);
    section.Build();
    if (!section.IsDone())
      throw std::runtime_error("surface intersection failed");
    auto &items = view->result(view->indices);
    for (const auto &edge : section.SectionEdges())
      items.push_back(view->addCurve(TopoDS::Edge(edge)));
    *out = {items.data(), items.size()};
  });
}

int project(HuakView *view, const size_t *curves, size_t count, int spline,
            double tolerance, ptrdiff_t *images, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(curves, count, "curves");
    requireArray(images, count, "images");
    for (size_t k = 0; k < count; ++k) {
      const auto &edge = view->curve(curves[k]);
      const auto image =
          spline ? projected(BRepBuilderAPI_MakeEdge(view->spline(curves[k])),
                             view->projector, tolerance)
                 : projected(edge, view->projector, tolerance);
      images[k] = image.IsNull() ? -1
                                 : static_cast<ptrdiff_t>(view->addImage(image));
    }
  });
}

int curveInfo(HuakView *view, const size_t *curves, size_t count,
              HuakCurveInfo *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(curves, count, "curves");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      const auto &edge = view->curve(curves[k]);
      double a, b;
      const auto curve = BRep_Tool::Curve(edge, a, b);
      out[k] = {!curve.IsNull() && curve->IsKind(STANDARD_TYPE(Geom_Line)),
                BRep_Tool::Tolerance(edge)};
    }
  });
}

int ranges(HuakView *view, const size_t *images, size_t count, HuakRange *out,
           char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(images, count, "images");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      const auto &plane = view->plane(images[k]);
      out[k] = {plane->FirstParameter(), plane->LastParameter()};
    }
  });
}

HuakBox boxOf(const Bnd_Box &box) {
  HuakBox result{};
  result.empty = box.IsVoid();
  if (!result.empty) {
    double z0, z1;
    box.Get(result.x0, result.y0, z0, result.x1, result.y1, z1);
  }
  return result;
}

int bounds(HuakView *view, const size_t *images, size_t count, HuakBox *out,
           char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(images, count, "images");
    require(out, "out");
    Bnd_Box box;
    for (size_t k = 0; k < count; ++k)
      BRepBndLib::Add(view->image(images[k]), box);
    *out = boxOf(box);
  });
}

int regionBounds(HuakView *view, const size_t *regions, size_t count,
                 HuakBox *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(regions, count, "regions");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      Bnd_Box box;
      BRepBndLib::Add(view->region(regions[k]), box);
      out[k] = boxOf(box);
    }
  });
}

int crossings(HuakView *view, const HuakPair *pairs, size_t count,
              HuakRows *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(pairs, count, "pairs");
    require(out, "out");
    auto &offsets = view->result(view->indices);
    auto &values = view->result(view->numbers);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      Geom2dAPI_InterCurveCurve inter(view->plane(pairs[k].first),
                                      view->plane(pairs[k].second),
                                      Precision::Confusion());
      auto &found = inter.Intersector();
      if (!found.IsDone())
        throw std::runtime_error("projected curve intersection failed");
      for (int i = 1; i <= found.NbPoints(); ++i)
        values.push_back(found.Point(i).ParamOnFirst());
      for (int i = 1; i <= found.NbSegments(); ++i) {
        auto &s = found.Segment(i);
        if (s.HasFirstPoint())
          values.push_back(s.FirstPoint().ParamOnFirst());
        if (s.HasLastPoint())
          values.push_back(s.LastPoint().ParamOnFirst());
      }
      offsets.push_back(values.size());
    }
    *out = {offsets.data(), values.data(), count};
  });
}

int pierce(HuakView *view, const HuakPair *pairs, size_t count, HuakRows *out,
           char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(pairs, count, "pairs");
    require(out, "out");
    auto &offsets = view->result(view->indices);
    auto &values = view->result(view->numbers);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      const auto &spline = view->spline(pairs[k].first);
      shapeOf(&view->model, pairs[k].second);
      auto &probe = view->model.probes[pairs[k].second];
      if (!probe)
        throw std::invalid_argument("shape has no faces");
      probe->Perform(new GeomAdaptor_Curve(spline), spline->FirstParameter(),
                     spline->LastParameter());
      if (!probe->IsDone())
        throw std::runtime_error("space curve intersection failed");
      for (int i = 1; i <= probe->NbPnt(); ++i)
        values.push_back(probe->WParameter(i));
      offsets.push_back(values.size());
    }
    *out = {offsets.data(), values.data(), count};
  });
}

int curvePoints(HuakView *view, const HuakCurvePoint *points, size_t count,
                HuakXYZ *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(points, count, "points");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      const auto &edge = view->curve(points[k].curve);
      gp_Pnt p = view->spline(points[k].curve)->Value(points[k].parameter);
      if (points[k].on_surface) {
        Handle(Geom2d_Curve) uv;
        Handle(Geom_Surface) surface;
        TopLoc_Location location;
        double u0, u1;
        BRep_Tool::CurveOnSurface(edge, uv, surface, location, u0, u1);
        if (!uv.IsNull()) {
          const auto at = uv->Value(points[k].parameter);
          p = surface->Value(at.X(), at.Y())
                  .Transformed(location.Transformation());
        }
      }
      copy(p.XYZ(), out[k].xyz);
    }
  });
}

int imagePoints(HuakView *view, const size_t *images, const double *parameters,
                size_t count, HuakXY *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(images, count, "images");
    requireArray(parameters, count, "parameters");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      const auto p = view->plane(images[k])->Value(parameters[k]);
      out[k] = {p.X(), p.Y()};
    }
  });
}

int approximate(HuakView *view, const HuakPiece *pieces, size_t count,
                double tolerance, HuakPaths *out, char *error,
                size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(pieces, count, "pieces");
    require(out, "out");
    auto &offsets = view->result(view->indices);
    auto &commands = view->result(view->paths);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      const auto &image = view->image(pieces[k].image);
      if (pieces[k].whole) {
        writeEdge(commands, image, tolerance);
      } else {
        double first, last;
        const auto curve = BRep_Tool::Curve(image, first, last);
        writeEdge(commands,
                  BRepBuilderAPI_MakeEdge(curve, pieces[k].first, pieces[k].last),
                  tolerance);
      }
      offsets.push_back(commands.size());
    }
    *out = {offsets.data(), commands.data(), count};
  });
}

int contours(HuakView *view, size_t source, size_t face,
             const double direction[3], double angle, double tolerance,
             HuakIndices *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(direction, "direction");
    require(out, "out");
    ShapeList images;
    traceContour(faceOf(&view->model, source, face),
                 gp_Dir(direction[0], direction[1], direction[2]), angle,
                 view->projector, tolerance, images);
    auto &items = view->result(view->indices);
    for (const auto &image : images)
      items.push_back(view->addImage(TopoDS::Edge(image)));
    *out = {items.data(), items.size()};
  });
}

int partition(HuakView *view, const HuakBox *rectangle, const size_t *domain,
              size_t domain_count, const size_t *tools, size_t tool_count,
              const HuakTracked *tracked, size_t tracked_count,
              HuakIndices *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(domain, domain_count, "domain");
    requireArray(tools, tool_count, "tools");
    requireArray(tracked, tracked_count, "tracked");
    require(out, "out");
    ShapeList objects, edges;
    if (rectangle) {
      objects.Append(BRepBuilderAPI_MakeFace(gp_Pln(gp::XOY()), rectangle->x0,
                                             rectangle->x1, rectangle->y0,
                                             rectangle->y1)
                         .Face());
    } else {
      BRep_Builder builder;
      TopoDS_Compound cells;
      builder.MakeCompound(cells);
      for (size_t k = 0; k < domain_count; ++k)
        builder.Add(cells, view->region(domain[k]));
      objects.Append(cells);
    }
    for (size_t k = 0; k < tool_count; ++k)
      edges.Append(view->image(tools[k]));
    std::vector<std::pair<size_t, TopoDS_Edge>> follow;
    for (size_t k = 0; k < tracked_count; ++k) {
      shapeOf(&view->model, tracked[k].source);
      follow.emplace_back(tracked[k].source, view->image(tracked[k].image));
    }
    const auto result =
        splitFaces(objects, edges, tracked_count ? &follow : nullptr,
                   &view->borders);
    auto &items = view->result(view->indices);
    for (TopExp_Explorer it(result, TopAbs_FACE); it.More(); it.Next())
      items.push_back(view->addRegion(TopoDS::Face(it.Current())));
    *out = {items.data(), items.size()};
  });
}

int interiors(HuakView *view, const size_t *regions, size_t count, HuakXY *out,
              char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(regions, count, "regions");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      gp_Pnt sample;
      gp_Pnt2d uv;
      if (BOPTools_AlgoTools3D::PointInFace(view->region(regions[k]), sample,
                                            uv, view->context))
        throw std::runtime_error("cannot locate projected face interior");
      out[k] = {sample.X(), sample.Y()};
    }
  });
}

int merge(HuakView *view, const HuakGroups *sets, const ptrdiff_t *keep,
          HuakGroups *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(sets, "sets");
    require(sets->offsets, "sets->offsets");
    require(out, "out");
    requireArray(keep, sets->count, "keep");
    for (size_t k = 0; k < sets->count; ++k)
      if (sets->offsets[k + 1] < sets->offsets[k])
        throw InvalidArgument("sets->offsets must not decrease");
    requireArray(sets->items, sets->offsets[sets->count], "sets->items");
    auto &offsets = view->result(view->indices);
    auto &items = view->result(view->indices);
    offsets.push_back(0);
    BRep_Builder builder;
    for (size_t k = 0; k < sets->count; ++k) {
      TopoDS_Compound cells;
      builder.MakeCompound(cells);
      for (size_t i = sets->offsets[k]; i < sets->offsets[k + 1]; ++i)
        builder.Add(cells, view->region(sets->items[i]));
      ShapeUpgrade_UnifySameDomain unify(cells, true, true);
      if (keep[k] >= 0)
        unify.KeepShapes(element(view->borders, static_cast<size_t>(keep[k]), "shape"));
      unify.Build();
      for (TopExp_Explorer it(unify.Shape(), TopAbs_FACE); it.More(); it.Next())
        items.push_back(view->addRegion(TopoDS::Face(it.Current())));
      offsets.push_back(items.size());
    }
    *out = {offsets.data(), items.data(), sets->count};
  });
}

int outlines(HuakView *view, const size_t *regions, size_t count,
             double tolerance, HuakPaths *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(regions, count, "regions");
    require(out, "out");
    auto &offsets = view->result(view->indices);
    auto &commands = view->result(view->paths);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      writeFace(commands, view->region(regions[k]), tolerance);
      offsets.push_back(commands.size());
    }
    *out = {offsets.data(), commands.data(), count};
  });
}

int moments(HuakView *view, const size_t *regions, size_t count,
            HuakMoments *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(regions, count, "regions");
    requireArray(out, count, "out");
    for (size_t k = 0; k < count; ++k) {
      GProp_GProps props;
      BRepGProp::SurfaceProperties(view->region(regions[k]), props, 1e-7);
      HuakMoments result{};
      result.area = props.Mass();
      copy(props.CentreOfMass().XYZ(), result.center);
      const GProp_PrincipalProps principal = props.PrincipalProperties();
      principal.Moments(result.moments[0], result.moments[1], result.moments[2]);
      copy(principal.FirstAxisOfInertia().XYZ(), result.axes[0]);
      copy(principal.SecondAxisOfInertia().XYZ(), result.axes[1]);
      copy(principal.ThirdAxisOfInertia().XYZ(), result.axes[2]);
      out[k] = result;
    }
  });
}
} // namespace

extern "C" __attribute__((visibility("default")))
const HuakProjectionV3 *huak_space_api_v3() {
  static const HuakProjectionV3 api{
      HUAK_SPACE_ABI_VERSION, sizeof(HuakProjectionV3),
      build,       releaseModel, shape,         same,        face,
      normalTurns, roots,        view,          releaseView, look,
      samples,     sightings,    rays,          curves,      edges,
      silhouettes, sections,     project,       curveInfo,   ranges,
      bounds,      regionBounds, crossings,     pierce,      curvePoints,
      imagePoints, approximate,  contours,      partition,   interiors,
      merge,       outlines,     moments};
  return &api;
}
