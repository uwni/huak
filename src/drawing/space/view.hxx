#pragma once
// The view the projection entries share, and the helpers that check their
// arguments and report OCCT's failures through the table's status codes.
#include "sights.hxx"
#include "space.hxx"
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRepGProp.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_B2.hxx>
#include <Bnd_Box.hxx>
#include <CSLib.hxx>
#include <ElSLib.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>
#include <Extrema_ExtPC2d.hxx>
#include <Geom2dAPI_ProjectPointOnCurve.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomConvert.hxx>
#include <GeomLib.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Line.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <IntCurvesFace_Intersector.hxx>
#include <IntTools_Context.hxx>
#include <BRepLib.hxx>
#include <NCollection_Array2.hxx>
#include <NCollection_IndexedDataMap.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <deque>
#include <gp_Cone.hxx>
#include <gp_Pln.hxx>
#include <limits>
#include <map>
#include <math_BracketedRoot.hxx>
#include <math_Function.hxx>
#include <stdexcept>
#include <string>

using namespace huak::space;

namespace huak::space::entry {
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
} // namespace huak::space::entry

using namespace huak::space::entry;

// Results stay where they are until the view is released: a deque does not
// move its elements, nor a vector its storage once filled.
struct HuakView {
  HuakView(HuakModel &model, const gp_Ax2 &axes, double focus)
      : model(model),
        projector(focus == 0 ? HLRAlgo_Projector(axes)
                             : HLRAlgo_Projector(axes, focus)),
        context(new IntTools_Context()) {}

  HuakModel &model;
  HLRAlgo_Projector projector;
  Handle(IntTools_Context) context;
  // Where lines of sight meet the faces, indexed on the first query.
  std::unique_ptr<huak::space::Sights> sightIndex;
  huak::space::Sights &sights() {
    if (!sightIndex)
      sightIndex = std::make_unique<huak::space::Sights>(model, projector);
    return *sightIndex;
  }
  std::vector<TopoDS_Edge> curves, images;
  std::vector<Handle(Geom_BSplineCurve)> splines;
  std::vector<Handle(Geom2d_Curve)> planes;
  // The curve each image shows, and whether the image is a line whose
  // parameter is its length rather than the curve's spline parameter.
  struct Source {
    size_t curve;
    bool line;
  };
  std::vector<Source> sources;
  // The edges of each face, by root shape and face index, as `edgesOf`
  // gathers them.
  std::map<std::pair<size_t, size_t>, ShapeSet> faceEdges;
  // An arc of the arrangement of images: a piece of the images between the
  // points where they cross, meet or end, as OCCT fused them, running its
  // curve's way; the images that run along it, one more than once where it
  // runs back along itself; its curve over its range in
  // the plane with the box about it, its tolerance, and whether it closes
  // on itself.
  struct Arc {
    TopoDS_Edge edge;
    // An image that runs along the arc: the part of the image's range
    // along it, and whether the arc keeps the image's curve over that
    // part, with its parameter.
    struct Along {
      size_t image;
      double first, last;
      bool keeps;
      // Beyond which end of the part the image leaves a stretch it runs
      // along another image in: 1 its last, -1 its first, 0 neither.
      int leaves;
      // Where the image passes the arc's middle.
      double middle;
    };
    std::vector<Along> along;
    Handle(Geom2dAdaptor_Curve) curve;
    Bnd_B2<double> box;
    double first = 0, last = 0, blur = 0;
    // The middle of the part of it that stands clear of its ends, beyond
    // their tolerances, as OCCT finds it.
    double middle = 0;
    // Its polyline: parameters of its curve from its first to its last and
    // its points there. Between two of them the arc goes one way, turns
    // little, and stands within that segment's of `offs` of the chord.
    std::vector<double> at;
    std::vector<gp_Pnt2d> points;
    std::vector<double> offs;
    // Where its ends stand, and how far the vertices there reach: within
    // that the arcs that meet there cannot be told apart.
    gp_Pnt2d tail, head;
    double tailReach = 0, headReach = 0;
    // Its parameters where it leaves those vertices, as `leaving` finds:
    // beyond them the arcs that meet there stand apart.
    double tailLeaves = 0, headLeaves = 0;
  };
  std::vector<Arc> arcs;
  std::deque<std::vector<HuakArc>> arcItems;
  std::deque<std::vector<HuakArcOrigin>> arcOrigins;
  std::deque<std::vector<HuakBox>> regionBoxes;
  std::deque<std::vector<HuakMoments>> regionMoments;
  // The curve index of each edge of the shapes, whichever query names it
  // first.
  std::map<size_t, NCollection_DataMap<TopoDS_Shape, size_t, TopTools_ShapeMapHasher>> edgeCurves;
  // For each curve on faces of the shapes, those faces as root shape and
  // face index; whether the face folds over along the curve, where its
  // normal is perpendicular to the line of sight; and whether the curve is
  // one drawn on the face's surface, which may run on beyond the face.
  struct OnFace {
    size_t source, face;
    bool folds;
    bool drawn = false;
  };
  std::map<size_t, std::vector<OnFace>> facesOf;
  std::deque<std::vector<size_t>> indices;
  std::deque<std::vector<double>> numbers;
  std::deque<std::vector<HuakPathCommand>> paths;
  std::deque<std::vector<HuakRim>> rims;
  std::deque<std::vector<HuakEdge>> edges;
  std::deque<std::vector<HuakSection>> sections;
  std::deque<std::vector<HuakSighting>> sightings;
  std::deque<std::vector<HuakShapeHit>> hits;
  std::deque<std::vector<HuakLayer>> layerItems;

  template <class T> std::vector<T> &result(std::deque<std::vector<T>> &store) {
    return store.emplace_back();
  }
  size_t addCurve(const TopoDS_Edge &edge) {
    curves.push_back(edge);
    splines.emplace_back();
    return curves.size() - 1;
  }
  // The curve of an edge of a root shape: the same index each time it is
  // named. One shape given as two roots has its curves once for each.
  size_t edgeCurve(size_t source, const TopoDS_Edge &edge) {
    if (const size_t *found = edgeCurves[source].Seek(edge))
      return *found;
    const size_t curve = addCurve(edge);
    edgeCurves[source].Bind(edge, curve);
    return curve;
  }
  size_t addImage(const TopoDS_Edge &edge, Source source) {
    images.push_back(edge);
    planes.emplace_back();
    sources.push_back(source);
    return images.size() - 1;
  }
  // The tolerance of the curve an image shows, in space.
  double curveTolerance(size_t index) const {
    return BRep_Tool::Tolerance(curves[element(sources, index, "image").curve]);
  }
  // Along a straight curve, as a part of it, the point whose image the
  // image of the curve has at parameter t. A camera with an eye does not
  // show a part of the curve as that part of its image.
  double alongLine(size_t index, double t) {
    const auto &source = element(sources, index, "image");
    double a, b;
    const auto curve = BRep_Tool::Curve(curves[source.curve], a, b);
    gp_Pnt p = curve->Value(a), q = curve->Value(b);
    const gp_Pnt2d shown = plane(index)->Value(t);
    projector.Transform(p);
    projector.Transform(q);
    const double scale = projector.Perspective() ? 1 - p.Z() / projector.Focus() : 1;
    const double shrink = projector.Perspective() ? -(q.Z() - p.Z()) / projector.Focus() : 0;
    const double x = (q.X() - p.X()) - shown.X() * shrink, y = (q.Y() - p.Y()) - shown.Y() * shrink;
    return std::abs(x) >= std::abs(y) ? (shown.X() * scale - p.X()) / x : (shown.Y() * scale - p.Y()) / y;
  }
  // The point of an image's curve in space where the image has parameter t.
  gp_Pnt spacePoint(size_t index, double t) {
    const auto &source = element(sources, index, "image");
    if (!source.line)
      return spline(source.curve)->Value(t);
    double a, b;
    const auto curve = BRep_Tool::Curve(curves[source.curve], a, b);
    const gp_Pnt p = curve->Value(a), q = curve->Value(b);
    return gp_Pnt(p.XYZ() + (q.XYZ() - p.XYZ()) * alongLine(index, t));
  }
  const TopoDS_Edge &curve(size_t index) const {
    return element(curves, index, "curve");
  }
  const TopoDS_Edge &image(size_t index) const {
    return element(images, index, "image");
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
  // The unit vector toward the viewer of an orthographic camera.
  gp_Dir eye() const {
    gp_Vec toward(0, 0, 1);
    toward.Transform(projector.InvertedTransformation());
    return gp_Dir(toward);
  }
  // The direction toward the viewer along the line of sight through a point:
  // toward the eye, at `focus` along `eye()`, of a perspective camera.
  gp_Vec toward(const gp_Pnt &point) const {
    if (!projector.Perspective())
      return gp_Vec(eye());
    return gp_Vec(point, gp_Pnt(projector.Focus() * eye().XYZ()));
  }
  double depth(const gp_Pnt &point) const {
    gp_Pnt local = point;
    projector.Transform(local);
    return local.Z();
  }
};

namespace huak::space::entry {
// projection.cpp
void copy(const gp_XYZ &from, double *to);
const TopoDS_Shape &shapeOf(const HuakModel *model, size_t source);
const TopoDS_Face &faceOf(const HuakModel *model, size_t source, size_t face);
bool normalOf(const Handle(Geom_Surface) & surface, const TopoDS_Face &face,
              const gp_Pnt2d &uv, gp_Dir &normal);

// The entries in view_curves.cpp, view_arrange.cpp, view_cells.cpp and
// view_regions.cpp, and the one helper two of them share.
int curves(HuakView *view, size_t source, HuakIndices *out, char *error,
           size_t capacity);
int edges(HuakView *view, size_t source, HuakEdges *out, char *error,
          size_t capacity);
int rims(HuakView *view, size_t source, HuakRims *out, char *error, size_t capacity);
int sections(HuakView *view, size_t first, size_t second, HuakSections *out,
             char *error, size_t capacity);
int project(HuakView *view, const size_t *curves, size_t count, int spline,
            double tolerance, ptrdiff_t *images, char *error, size_t capacity);
int pierce(HuakView *view, const HuakPair *pairs, size_t count, HuakRows *out,
           char *error, size_t capacity);
int approximate(HuakView *view, const HuakPiece *pieces, size_t count,
                double tolerance, HuakPaths *out, char *error,
                size_t capacity);
int contours(HuakView *view, size_t source, size_t face,
             const double direction[3], double angle, HuakIndices *out,
             char *error, size_t capacity);
int arrange(HuakView *view, const size_t *images, size_t count, const HuakCut *cuts,
            size_t cut_count, HuakArcs *out, char *error, size_t capacity);
int cells(HuakView *view, HuakCells *out, char *error, size_t capacity);
int fill(HuakView *view, const size_t *offsets, const HuakTurnedArc *arcs, size_t count, double tolerance,
         HuakPaths *out, char *error, size_t capacity);
int regions(HuakView *view, const size_t *offsets, const HuakTurnedArc *arcs, size_t count, double tolerance,
            int compute_moments, HuakRegions *out, char *error, size_t capacity);
// The parameter at which an arc leaves the vertex at `centre` that reaches
// `reach`, from its tail or from its head: where it first stands that far
// from the centre, or where it stands nowhere so far, where it stands
// farthest. The arrangement finds it once for each end of each arc.
double leaving(const HuakView::Arc &arc, bool fromTail, const gp_Pnt2d &centre, double reach);
} // namespace huak::space::entry
