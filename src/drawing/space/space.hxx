#pragma once
// Declarations shared by the OCCT adapter's translation units. The adapter
// builds shapes and answers queries about them; Huak decides what to draw.
#include "projection.h"
#include <Geom2d_Curve.hxx>
#include <Geom_Curve.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Vec2d.hxx>
#include <HLRAlgo_Projector.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <NCollection_DataMap.hxx>
#include <NCollection_IndexedMap.hxx>
#include <NCollection_List.hxx>
#include <NCollection_Map.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Vertex.hxx>
#include <algorithm>
#include <cmath>
#include <functional>
#include <math_Function.hxx>
#include <memory>
#include <utility>
#include <vector>

namespace huak::space {
using ShapeList = NCollection_List<TopoDS_Shape>;
using ShapeIndex =
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>;
using ShapeSet = NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher>;

// How far a curve may turn, in radians, between two points sampled along it.
// It sets how finely curves are cut into the segments of the polylines that
// bound them, and so how tight those bounds are; what they tell holds while
// a curve turns less than a right angle over three segments in a row, as
// the clearance of an arc in view_cells.cpp takes it to.
inline constexpr double turning = 0.2;
static_assert(3 * turning < M_PI / 2, "three segments in a row turn less than a right angle");

// A scalar function of one parameter for OCCT's root finders and minimizers.
class Scalar : public math_Function {
public:
  explicit Scalar(const std::function<double(double)> &value) : value(value) {}
  bool Value(double s, double &f) override {
    f = value(s);
    return true;
  }

private:
  const std::function<double(double)> &value;
};

TopoDS_Shape buildShape(const HuakModelShape &,
                        const std::vector<TopoDS_Shape> &, double tolerance);
// The image of an edge in the projection plane z = 0; null where it collapses
// to a point.
TopoDS_Edge projected(const TopoDS_Edge &, const HLRAlgo_Projector &,
                      double tolerance);
// The most the projection stretches a short distance near an edge: one for an
// orthographic projector, and for a perspective one a bound over the edge's
// box.
double magnification(const TopoDS_Edge &, const HLRAlgo_Projector &);
// An image edge's curve as a planar curve, with the same parameter.
Handle(Geom2d_Curve) inPlane(const TopoDS_Edge &);
// Appends an image edge as path commands within `tolerance`, starting with a
// move when `move` is set.
void writeEdge(std::vector<HuakPathCommand> &, const TopoDS_Edge &,
               double tolerance, bool move = true);
// Appends each wire of a planar face as a closed path.
void writeFace(std::vector<HuakPathCommand> &, TopoDS_Face, double tolerance);
// The part of an image that an arc comes from: the image's index, and the
// range of its curve along the arc.
struct ToolPart {
  size_t tool;
  double first, last;
  // Where the arc is part of a stretch along which the image runs within
  // tolerance of a bounding image: beyond which end of its part the image
  // leaves the stretch, 1 its last, -1 its first; 0 otherwise.
  int leaves = 0;
};
// An arc of an arrangement of images: an edge of the plane with a vertex at
// each end, which arcs that meet there share, and the parts of the images
// it comes from, its own curve's first: several where images run within
// tolerance of each other.
struct ArcPiece {
  TopoDS_Edge edge;
  std::vector<ToolPart> parts;
  // Its curve in the plane, over the range of its edge.
  Handle(Geom2d_Curve) plane;
  // The arc's polyline: parameters of its curve from its first to its last
  // and its points there. Between two of them the arc goes one way, turns
  // little, and stands within that segment's of `offs` of the chord.
  std::vector<double> at;
  std::vector<gp_Pnt2d> points;
  std::vector<double> offs;
};
// Where an image passes a point: the image's index and its parameter.
struct Passage {
  size_t image;
  double at;
};
// A point of the plane where images meet, as the curves they show meet in
// space: each that passes within `within` of it passes through it.
struct Meeting {
  gp_Pnt2d at;
  double within;
};
// Arranges images, edges of the plane z = 0, into the arcs between the
// points where they meet: at `meetings`, where they cross each other, and
// at `cuts`. `bounding` tells of each image whether what lies beside
// it may differ from one side of it to the other: along such an image, what
// covers another that runs within tolerance of it cannot be told.
std::vector<ArcPiece> arrangeImages(const std::vector<TopoDS_Edge> &images,
                                    const std::vector<bool> &bounding, const std::vector<Meeting> &meetings,
                                    const std::vector<Passage> &cuts);
// Contours on a face as they are marched on its parameters: edges through
// points OCCT's contour function puts on the contour, OCCT's lines and
// circles where the contour is one, and else splines fitted both in space
// and on the face; and the edges of the face that a contour runs along.
// Every end lies on an edge of the face, at a singular point of its
// parametrization, or at another end; a contour left open elsewhere throws.
struct Contours {
  std::vector<TopoDS_Edge> curves;
  std::vector<TopoDS_Edge> along;
};
// The curves on `face` where the normal makes `angle` with `direction`.
std::vector<TopoDS_Edge> traceContours(TopoDS_Face, gp_Dir direction, double angle);
// The face's outline as the projector sees it: where the line of sight
// grazes the face. A plane has none.
Contours traceOutlines(const TopoDS_Face &, const HLRAlgo_Projector &);
// The face's singular points: the vertices of its degenerated edges, where
// its parametrization collapses to a point, as at a sphere's pole or a
// cone's apex.
std::vector<TopoDS_Vertex> singularPoints(const TopoDS_Face &);

// Halves the parts between parameters that are marked.
inline void halve(std::vector<double> &at, const std::vector<bool> &split) {
  std::vector<double> finer;
  finer.reserve(at.size() * 2);
  finer.push_back(at.front());
  for (size_t k = 0; k + 1 < at.size(); ++k) {
    if (split[k])
      finer.push_back((at[k] + at[k + 1]) / 2);
    finer.push_back(at[k + 1]);
  }
  at = std::move(finer);
}

// How far along a segment, as a part of it, a point stands nearest.
inline double along(const gp_Pnt2d &p, const gp_Pnt2d &a, const gp_Pnt2d &b) {
  const gp_Vec2d way(a, b);
  const double length2 = way.SquareMagnitude();
  return length2 > 0 ? std::clamp(gp_Vec2d(a, p).Dot(way) / length2, 0.0, 1.0) : 0.0;
}

// How far a point stands from a segment.
inline double apart(const gp_Pnt2d &p, const gp_Pnt2d &a, const gp_Pnt2d &b) {
  return p.Distance(a.Translated(gp_Vec2d(a, b) * along(p, a, b)));
}

// How far two segments stand apart: nothing where they cross, otherwise the
// least an end of one stands from the other.
inline double apart(const gp_Pnt2d &a, const gp_Pnt2d &b, const gp_Pnt2d &c, const gp_Pnt2d &d) {
  const auto side = [](const gp_Pnt2d &from, const gp_Pnt2d &to, const gp_Pnt2d &p) {
    return gp_Vec2d(from, to).Crossed(gp_Vec2d(from, p));
  };
  if (side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0)
    return 0;
  return std::min({apart(a, c, d), apart(b, c, d), apart(c, a, b), apart(d, a, b)});
}

// How far along two segments, as parts of them, they stand nearest each
// other: where they cross, otherwise where an end of one stands nearest the
// other.
inline std::pair<double, double> nearestAlong(const gp_Pnt2d &a, const gp_Pnt2d &b, const gp_Pnt2d &c, const gp_Pnt2d &d) {
  const gp_Vec2d ab(a, b), cd(c, d), ac(a, c);
  const double turned = ab.Crossed(cd);
  if (std::abs(turned) > gp::Resolution()) {
    const double s = ac.Crossed(cd) / turned, r = ac.Crossed(ab) / turned;
    if (s >= 0 && s <= 1 && r >= 0 && r <= 1)
      return {s, r};
  }
  std::pair<double, double> best{0, along(a, c, d)};
  double least = apart(a, c, d);
  if (const double away = apart(b, c, d); away < least) {
    least = away;
    best = {1, along(b, c, d)};
  }
  if (const double away = apart(c, a, b); away < least) {
    least = away;
    best = {along(c, a, b), 0};
  }
  if (const double away = apart(d, a, b); away < least)
    best = {along(d, a, b), 1};
  return best;
}
} // namespace huak::space

// The root shapes of one build, their faces, and an intersector for each
// shape with faces.
struct HuakModel {
  std::vector<TopoDS_Shape> shapes;
  std::vector<huak::space::ShapeIndex> faces;
  std::vector<std::unique_ptr<IntCurvesFace_ShapeIntersector>> probes;
  double tolerance = 0;
};
