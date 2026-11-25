#pragma once
// What the contour tracer's translation units share: OCCT's contour
// function on the face's parameters, the samples traced and the curves
// fitted to them, the edges built from those, and the trace on a grid.
#include "contour_function.hxx"
#include "space.hxx"
#include <Adaptor2d_Curve2d.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BSplCLib.hxx>
#include <Geom2dAPI_ProjectPointOnCurve.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Surface.hxx>
#include <GeomLib.hxx>
#include <GeomConvert_CurveToAnaCurve.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Line.hxx>
#include <ElCLib.hxx>
#include <gp_Circ.hxx>
#include <gp_Lin.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <Geom2dAPI_InterCurveCurve.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2d_Line.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <functional>
#include <map>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <math_Matrix.hxx>
#include <math_Vector.hxx>
#include <math_BracketedRoot.hxx>
#include <math_Function.hxx>
#include <math_GaussSingleIntegration.hxx>
#include <optional>

namespace huak::space::contour {
// A singular point of a face: a degenerated edge, all of whose curve on the
// face stands for the one point.
struct Singular {
  gp_Pnt at;
  double reach;
  Handle(Geom2d_Curve) arc;
  double first, last;
};
std::vector<Singular> singularArcs(const TopoDS_Face &face);

// A point of a contour: on the face's parameters and in space; whether it
// lies on an edge of the face, and whether the contour is cut there; the
// singular point of the face it stands at, where it does; and how far
// along the traced contour it lies.
struct Sample {
  gp_Pnt2d uv;
  gp_Pnt p;
  bool edge = false, cut = false;
  const Singular *singular = nullptr;
  double along = 0;
};

// The curve on the face and the space curve through samples of a contour,
// over the parameters `at`, and the tolerance the space curve keeps from
// the contour, as fitting measures it. The curve on the face leads from the
// space curve's parameters to the contour.
struct Fit {
  Handle(Geom2d_BSplineCurve) curve2d;
  Handle(Geom_BSplineCurve) curve;
  std::vector<double> at;
  double tolerance = 0;
};
Fit fitContour(std::vector<Sample> samples, const Handle(Geom_Surface) & surface, const OnContour &onContour,
               const std::function<Sample(double)> &locate);

// A contour as one of OCCT's lines or circles: the curve, the range over
// which it runs from the first sample to the last, and the tolerance it
// keeps from the contour, as it is measured.
struct Exact {
  Handle(Geom_Curve) curve;
  double first, last, tolerance;
};
std::optional<Exact> exactCurve(const std::vector<Sample> &samples, const Handle(Geom_Surface) & surface,
                                const OnContour &onContour);

// Edges traced on one face, sharing vertices where they meet.
class Builder {
public:
  explicit Builder(const TopoDS_Face &face) : surface(BRep_Tool::Surface(face)) {}

  // The vertex of an edge made so far that stands at a point, or a new one.
  TopoDS_Vertex vertexAt(const gp_Pnt &p) {
    for (const auto &v : vertices)
      if (BRep_Tool::Pnt(v).Distance(p) <= BRep_Tool::Tolerance(v) + Precision::Confusion())
        return v;
    TopoDS_Vertex made;
    BRep_Builder().MakeVertex(made, p, Precision::Confusion());
    vertices.push_back(made);
    return made;
  }

  // An edge over [first, last] of a space curve that stands within
  // `tolerance` of the contour. What the edges are drawn and arranged from
  // needs no curve on the face, and none is kept.
  void add(const Handle(Geom_Curve) & curve, double first, double last, const TopoDS_Vertex &from,
           const TopoDS_Vertex &to, double tolerance) {
    TopoDS_Edge edge;
    BRep_Builder builder;
    builder.MakeEdge(edge, curve, tolerance);
    builder.Add(edge, from.Oriented(TopAbs_FORWARD));
    builder.Add(edge, to.Oriented(TopAbs_REVERSED));
    builder.Range(edge, first, last);
    for (TopExp_Explorer v(edge, TopAbs_VERTEX); v.More(); v.Next())
      if (BRep_Tool::Tolerance(TopoDS::Vertex(v.Current())) < tolerance)
        builder.UpdateVertex(TopoDS::Vertex(v.Current()), tolerance);
    edges.push_back(edge);
  }

  const Handle(Geom_Surface) surface;
  std::vector<TopoDS_Edge> edges;

private:
  std::vector<TopoDS_Vertex> vertices;
};
void requireClosedEnds(const TopoDS_Face &face, const std::vector<TopoDS_Edge> &edges);

// Where a piece of the contour leaves the triangle it runs through, across
// a line of the grid between two nodes and back again, which the nodes tell
// nothing of: the cell of the grid that holds the triangle.
struct Unresolved {
  size_t i, j;
};

// The contours of a face traced on a grid of its parameters, `us` by `vs`,
// as `march` makes it, and the edges of the face the contour runs along. A
// node where the function `function` is within rounding of nil counts as
// past the contour. Each cell is two triangles, but for a cell whose
// corners alternate sides of the contour: it holds a point where the
// function's gradient vanishes, as Newton's method finds it, and is four
// triangles about it, so that which side that point lies on decides how
// the contour goes through the cell; where the function vanishes there as
// far as rounding tells, the contour crosses itself there. The contour
// crosses each edge of a triangle whose ends lie on either side, and runs
// within the triangle between the two edges it crosses, apart from the
// vertex alone on its side; the pieces chain into paths. A path is the
// face's where OCCT's classifier finds its points in the face; where it
// leaves the face between two points, it ends where the contour crosses the
// edge of the face that their chord crosses, at the function's root along
// the edge. Paths are cut where they meet an edge of the face or cross
// themselves; each piece is sampled evenly along its length, each sample
// where the contour crosses the line from the lone vertex of the triangle it
// runs through, and fitted. Throws `Unresolved` where a piece leaves its
// triangle in a cell the grid can still halve.
//
// Building the trace lays out the grid and chains the crossings into
// paths; `edges` traces the paths and fits the edges.
class GridTrace {
public:
  GridTrace(const TopoDS_Face &face, const ContourFunction &function, const std::vector<double> &us,
            const std::vector<double> &vs, const std::vector<TopoDS_Edge> &along);
  std::vector<TopoDS_Edge> edges();

private:
  // The triangles. A cell whose corners alternate sides holds the point of
  // its own where the gradient vanishes, or else the saddle of the bilinear
  // interpolant of its corners' values.
  struct Triangle {
    std::array<size_t, 3> at;
    size_t i, j;
  };
  // Where the contour crosses each edge of a triangle whose ends lie on
  // either side; and the node it stands at, where it does.
  struct Crossing {
    gp_Pnt2d uv;
    gp_Pnt p;
    std::optional<size_t> node;
  };
  // The pieces of the contour within triangles: between its crossings of
  // the two edges at the triangle's vertex alone on its side, which with
  // the other two, its base, the piece parts.
  struct Link {
    size_t ends[2];
    size_t lone, base[2];
    size_t i, j;
  };
  // The paths: from each end, then around each loop; the crossings along
  // each and the pieces between them.
  struct Path {
    std::vector<size_t> at, through;
  };
  // A traced piece of contour: its points, and the pieces within triangles
  // between each two in a row.
  struct Piece {
    std::vector<Sample> points;
    std::vector<size_t> through;
  };

  const TopoDS_Face &face;
  const ContourFunction &function;
  const std::vector<double> &us, &vs;
  const std::vector<TopoDS_Edge> &along;
  Builder built;
  OnContour onContour;
  const Handle(Geom_Surface) &surface;
  // The sides of the grid along a degenerated edge, all of whose curve on
  // the face stands for one singular point: the face's parameters there
  // tell nothing of the normal, which depends on the way the point is come
  // to. The function is taken inside such a side, on the line of the grid
  // that comes to the point, by the step GeomLib::NormEstim takes off a
  // singular point.
  const std::vector<Singular> singular;
  double floor[2] = {-RealLast(), -RealLast()}, ceiling[2] = {RealLast(), RealLast()};
  // The nodes: the grid's, row by row, then the points added in cells; the
  // function at each and the most rounding may leave it there; and whether
  // each is one where the function's gradient vanishes.
  std::vector<gp_Pnt2d> nodes;
  std::vector<ContourFunction::Reading> readings;
  std::vector<bool> critical;
  std::vector<Triangle> triangles;
  std::vector<Crossing> crossings;
  std::map<std::pair<size_t, size_t>, size_t> crossingOf;
  std::vector<Link> links;
  std::vector<std::vector<size_t>> linksAt;
  std::vector<Path> paths;
  std::vector<bool> used;
  // Whether a point of the face's parameters lies in the face, as OCCT
  // classifies it.
  BRepTopAdaptor_FClass2d classifier;

  ContourFunction::Reading valueAt(const gp_Pnt2d &uv) const {
    return function.value(std::clamp(uv.X(), floor[0], ceiling[0]), std::clamp(uv.Y(), floor[1], ceiling[1]));
  }
  gp_Vec2d gradientAt(const gp_Pnt2d &uv) const {
    const auto reading =
        function.values(std::clamp(uv.X(), floor[0], ceiling[0]), std::clamp(uv.Y(), floor[1], ceiling[1]));
    return gp_Vec2d(reading.du, reading.dv);
  }
  // Whether a reading is past the contour, and whether it vanishes, as far
  // as rounding tells. A value beyond its rounding has the function's sign,
  // as a floating-point filter decides a sign (Fortune and Van Wyk 1993;
  // Shewchuk 1997, section 4.2). One within it is taken to vanish, where a
  // filter would leave its sign to exact arithmetic (Shewchuk's later
  // stages); and one that vanishes counts as past, as marching cubes counts
  // a vertex whose value equals the surface's as inside (W. E. Lorensen and
  // H. E. Cline, "Marching cubes: a high resolution 3D surface construction
  // algorithm", Computer Graphics 21 (1987) 163-169, section 4). Nil is
  // among them where OCCT's normal is nil and leaves no rounding, as by a
  // pole of a surface of revolution.
  static bool past(const ContourFunction::Reading &reading) { return reading.value >= -reading.rounding; }
  static bool vanishes(const ContourFunction::Reading &reading) { return std::abs(reading.value) <= reading.rounding; }
  bool past(size_t node) const { return past(readings[node]); }
  std::optional<gp_Pnt2d> criticalIn(const gp_Pnt2d &lo, const gp_Pnt2d &hi, const gp_Pnt2d &start) const;
  gp_Pnt2d rootBetween(const gp_Pnt2d &from, const ContourFunction::Reading &reading, const gp_Pnt2d &to) const;
  size_t crossing(size_t a, size_t b);
  gp_Pnt2d onLink(const Link &link, const gp_Pnt2d &x);
  void follow(size_t start);

  std::optional<Sample> leaving(const gp_Pnt2d &in, const gp_Pnt2d &out);
  const Singular *singularAt(const gp_Pnt &p) const;
  bool onAlong(const gp_Pnt &p) const;
  bool onEdge(const gp_Pnt2d &uv, TopAbs_State state) const;
  void trace(Piece piece, bool closed);
  void finish(Piece run);
};
} // namespace huak::space::contour
