#pragma once
// The arrangement of images: curves of the plane cut into the arcs between
// the points where they meet.
//
// Images meet where the curves they show meet in space, which the caller
// tells, and where they cross or touch in the plane. Each image has a
// polyline with a bound on how far the image stands from each segment of
// it; two segments whose bounds keep them apart do not meet, and the others
// are halved until OCCT's search from where their chords cross finds the
// crossing, or until they are too near their chords to tell from them and
// come within tolerance there. Each point where images meet is one vertex,
// which every image through it shares; it covers the images as far as they
// stand within tolerance of each other next to it. Where two images run
// within tolerance of each other for longer, along a stretch, they are one
// curve of the plane as far as it can be told: one arc stands for them
// both. An image that turns back runs along itself the same way: it is cut
// where it turns, and its parts on either side of a turn are related as two
// images are. What is too short for OCCT to tell from its ends is no arc:
// its ends are one point.
#include "space.hxx"
#include <BOPTools_AlgoTools.hxx>
#include <BSplCLib.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_B2.hxx>
#include <Extrema_LocateExtCC2d.hxx>
#include <Extrema_POnCurv2d.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2dConvert_BSplineCurveToBezierCurve.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_BezierCurve.hxx>
#include <Geom2d_Line.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <IntTools_Context.hxx>
#include <PLib.hxx>
#include <Precision.hxx>
#include <TopExp.hxx>
#include <TopoDS.hxx>
#include <math_BracketedRoot.hxx>
#include <math_BrentMinimum.hxx>
#include <math_Function.hxx>
#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <map>
#include <stdexcept>
#include <string>

namespace huak::space {

// Images that come within what tells them apart meet. Having met, they run
// along each other for as long as they keep within `lingering` times that, so
// that where they part does not hang on the last digit of how near they
// stand; and what parts again within `covered` times as far as that from
// where they met is no stretch along which they run, but part of the point
// where they meet.
//
// Neither decides what the arrangement shows, only how it tells it. Any
// `lingering` above one parts images beyond where they are told apart, and
// moves where a stretch ends only among points where the two stand within
// `lingering` times what tells them apart. A meeting that parts soon is a
// vertex, or a vertex and a stretch from it, and either bounds the same
// cells; the vertex that covers it reaches about `covered` + 1 times
// `lingering` times what tells the images apart, which has to stay well
// within the tolerance of the drawing.
inline constexpr double lingering = 4;
static_assert(lingering > 1, "images part beyond where they are told apart");
inline constexpr double covered = 16;

class Arranging {
public:
  Arranging(const std::vector<TopoDS_Edge> &edges, const std::vector<bool> &bounding);

  void meet(const gp_Pnt2d &at, double within);

  void cut(const Passage &where);

  std::vector<ArcPiece> arcs();

private:
  // A cut of an image: its parameter, the image's point there, and the
  // vertex the image's pieces share there.
  struct Cut {
    double at;
    gp_Pnt2d point;
    size_t vertex;
  };
  // How a part of an image lies about the chord between its ends: how far
  // it may stand from the chord; and, where every step between its control
  // points heads within a right angle of the chord, the least and the most
  // angle they head at from it, between which it heads all along.
  struct Hull {
    double off = 0;
    bool headed = false;
    double low = 0, high = 0;
  };
  // A part of an image between two of its parameters: its ends, and how it
  // lies about the chord between them.
  struct Part {
    double first, last;
    gp_Pnt2d from, to;
    Hull hull;
    // How far it may reach across: no farther than the chord and twice what
    // it may stand from it.
    double size() const { return from.Distance(to) + 2 * hull.off; }
  };
  // A part of a segment of an image's polyline, and, once it has been
  // halved, the first of the two parts that are its halves, the second
  // next to it.
  struct Node {
    Part part;
    size_t halves = 0;
  };
  // A piece of an image's curve: a rational Bézier curve, and the
  // coefficients of its polynomials, and of its weights' where it has
  // weights, from which OCCT cuts it to a part of its range.
  struct Bezier {
    Handle(Geom2d_BezierCurve) curve;
    std::vector<gp_Pnt2d> coefficients;
    std::vector<double> weights;
  };
  // An image: its curve over its range, its tolerance, and whether what
  // lies beside it may differ from one side to the other; its curve in
  // pieces as OCCT cuts its spline at its knots, each a rational Bézier
  // curve over its part of the range, between two of `knots`: over a
  // piece, the curve stays within the convex hull of the piece's control
  // points and heads only among the directions of the steps between them
  // in order; its polyline, over each segment of which it heads within
  // `turning` of one way or goes no farther than OCCT tells apart, with
  // what it may stand from the segment, the most it stands from any, and
  // the box about them; the parts of the segments it has been halved into,
  // the segments first; the parameters where it turns back, each a point
  // of the polyline; and its cuts in order along it.
  struct Image {
    TopoDS_Edge edge;
    Handle(Geom2d_Curve) plane;
    Handle(Geom2dAdaptor_Curve) adaptor;
    double first = 0, last = 0, blur = 0;
    bool bounds = false;
    std::vector<double> knots;
    std::vector<Bezier> beziers;
    std::vector<double> at;
    std::vector<gp_Pnt2d> points;
    std::vector<double> offs;
    double off = 0;
    Bnd_B2<double> box;
    std::vector<Node> nodes;
    std::vector<double> turns;
    std::vector<Cut> cuts;
  };
  // A part of an image's range that holds no turn of it.
  struct Span {
    double lo, hi;
    bool operator==(const Span &other) const { return lo == other.lo && hi == other.hi; }
  };
  // A stretch: from a point where two parts of images meet, the part of one
  // along which it runs within tolerance of the other, and the other's part
  // beside it, neither turning back; `anchor` and `beside` are their
  // parameters at the point; and how many cuts each image had when the two
  // parts were last cut alike.
  struct Stretch {
    size_t tool;
    double first, last, anchor;
    size_t other;
    double from, to, beside;
    size_t mine = 0, theirs = 0;
  };
  // A piece of an image between two of its cuts.
  struct Piece {
    size_t tool;
    double lo, hi;
    size_t from, to;
  };
  // A vertex: where it stands and how far it reaches; the passages through
  // it, any two of which are known to part within it or to run on along a
  // stretch; how far it reached when the images passing within it, and the
  // vertices it reaches, were last sought; and the vertex it has become one
  // with, itself while it stands.
  struct Meet {
    TopoDS_Vertex vertex;
    gp_Pnt2d at;
    double reach;
    std::vector<Passage> through;
    double passed = -1, compared = -1;
    size_t same;
  };

  std::vector<Image> images;
  std::vector<Stretch> stretches;
  // For each image, the stretches along which it runs.
  std::vector<std::vector<size_t>> stretchesOf;
  // How many of the stretches are cut at their ends, where one part leaves
  // the other.
  size_t ended = 0;
  std::vector<Meet> meets;
  std::map<const void *, size_t> known;
  std::vector<Piece> pieces;
  std::vector<std::pair<size_t, size_t>> piecesOf;
  std::vector<size_t> bundle;
  std::map<size_t, std::vector<size_t>> bundles;
  BRep_Builder builder;
  Handle(IntTools_Context) context;

  gp_Pnt2d at(size_t k, double t) const { return images[k].adaptor->Value(t); }

  // The vertex that stands for one, which may have become one with another.
  size_t standing(size_t vertex) const {
    while (meets[vertex].same != vertex)
      vertex = meets[vertex].same;
    return vertex;
  }
  size_t meetOf(const TopoDS_Vertex &vertex);
  size_t vertexAt(const gp_Pnt2d &at, double reach);
  void grow(size_t vertex, double reach);

  static void cutIntoPieces(Image &image);

  // Calls `visit` with the control points of each piece of an image's
  // curve over [a, b], cut to its part within [a, b] as OCCT's Bézier
  // curve cuts itself: its coefficients trimmed to the part, and the
  // control points and weights of those.
  template <class Visit> void hullOver(size_t k, double a, double b, const Visit &visit) const {
    const auto &image = images[k];
    const auto &knots = image.knots;
    size_t n = static_cast<size_t>(std::upper_bound(knots.begin(), knots.end(), a) - knots.begin());
    n = std::min(n == 0 ? 0 : n - 1, image.beziers.size() - 1);
    for (; n < image.beziers.size() && knots[n] < b; ++n) {
      const double lo = std::max(a, knots[n]), hi = std::min(b, knots[n + 1]);
      if (!(hi > lo))
        continue;
      const auto &piece = image.beziers[n];
      if (lo == knots[n] && hi == knots[n + 1]) {
        visit(piece.curve->Poles());
        continue;
      }
      const double span = knots[n + 1] - knots[n];
      const int count = piece.curve->NbPoles();
      std::array<gp_Pnt2d, 26> trimmed, cut;
      std::array<double, 26> trimmedWeights, cutWeights;
      std::copy(piece.coefficients.begin(), piece.coefficients.end(), trimmed.begin());
      NCollection_Array1<gp_Pnt2d> coefficients(trimmed.front(), 1, count), poles(cut.front(), 1, count);
      if (piece.weights.empty()) {
        PLib::Trimming((lo - knots[n]) / span, (hi - knots[n]) / span, coefficients, PLib::NoWeights());
        PLib::CoefficientsPoles(coefficients, PLib::NoWeights(), poles, PLib::NoWeights());
      } else {
        std::copy(piece.weights.begin(), piece.weights.end(), trimmedWeights.begin());
        NCollection_Array1<double> weightCoefficients(trimmedWeights.front(), 1, count), weights(cutWeights.front(), 1, count);
        PLib::Trimming((lo - knots[n]) / span, (hi - knots[n]) / span, coefficients, &weightCoefficients);
        PLib::CoefficientsPoles(coefficients, &weightCoefficients, poles, &weights);
      }
      visit(poles);
    }
  }

  Hull hullOf(size_t k, double a, double b, const gp_Pnt2d &from, const gp_Pnt2d &to) const;

  void outline(size_t k);

  Span spanOf(size_t k, double t, int way) const;
  bool turnsAt(size_t k, double t) const;

  size_t segmentAt(size_t k, double t) const;
  std::pair<size_t, size_t> segmentsOver(size_t k, double lo, double hi) const;
  std::pair<double, double> nearestOver(const gp_Pnt2d &p, size_t k, size_t from, size_t to,
                                        double lo = -RealLast(), double hi = RealLast()) const;
  std::pair<double, double> nearest(const gp_Pnt2d &p, size_t k, double lo, double hi, const double *seed = nullptr) const;

  bool staysWithin(size_t k, double a, double b, const gp_Pnt2d &centre, double r) const;
  bool within(size_t k, double lo, double hi, size_t vertex) const;

  const Cut *cutNear(size_t k, double t) const;

  // How far a part of an image runs along a part of another, one way from
  // where both pass a point, the other at `seed`: as far as it is proven to
  // stay within four times their tolerances of the other's part, `along`,
  // no farther than `room`, to where it turns back or ends; the other's
  // parameters beside the point and beside where the run is proven to; and
  // how far from the point the image may come before it is proven to part,
  // which a vertex covering the meeting must reach. Nothing where they
  // stand farther apart at the point.
  //
  // A piece of the image and the other's piece between the points nearest
  // its ends lie within their hulls' `off` of their chords; where each
  // heads within a right angle of its chord, every point of the chord also
  // lies within that of the piece. So any point of one piece stands from the
  // other piece no farther than the farther end of its chord stands from the
  // other's chord, with both offs; and no nearer than the chords stand
  // apart, less both offs. The run is proven piece by piece from the point,
  // each piece twice as long as the last; a piece not proven is halved, and
  // where the second half of it is proven to stand apart, the run ends
  // before that. Their directions and bending at the point tell about where
  // they part: where the pieces from twice to four times that far on are
  // proven apart, the run ends within twice as far. It ends where its next
  // piece is too short for OCCT to tell from its ends.
  struct Run {
    double reach, from, beside, far;
  };
  Run runsAlong(size_t k, double t, int way, double room, size_t other, double seed, const Span &along) const;

  bool running(size_t k, double t, int way, size_t other, double w) const;

  void relate(size_t vertex, const Passage &one, const Passage &other);

  size_t unite(size_t one, size_t other);

  bool pass(size_t k, double t, size_t vertex);

  bool settled(size_t i, double u, size_t j, double w) const;

  std::pair<size_t, size_t> halves(size_t k, size_t node);

  bool related(size_t i, const Part &a, size_t j, const Part &b) const;

  void meetAt(size_t i, double u, size_t j, double w);

  static bool headApart(const Part &a, const Part &b);
  static double beyond(const gp_Pnt2d &p, const Part &part);
  static int winding(const Part &a, const Part &b);

  void resolve(size_t i, size_t node, size_t j, size_t theirNode);

  void cross();

  bool join(size_t k, double t, size_t other, double beside);

  bool alike();

  bool through();

  bool coincide();

  bool divide();
  size_t bundleOf(size_t i) const;

  TopoDS_Edge edgeOf(const Piece &piece, double tolerance);

  double spreadOf(size_t lead, const std::vector<size_t> &members) const;

  bool shorten();

  bool cover();

  void close();

  int leaving(const Piece &piece) const;

  std::vector<ArcPiece> emit();
};
} // namespace huak::space
