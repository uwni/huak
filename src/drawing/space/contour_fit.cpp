// A line, a circle or splines through the samples of one traced piece of a
// contour.
#include "contours.hxx"
#include <limits>
#include <math_BrentMinimum.hxx>
#include <math_PSO.hxx>

namespace huak::space::contour {
namespace {
// The order of the splines fitted: one more than their degree.
constexpr int order = 6;
// The most a span between two samples may be longer than a span next to
// it. A spline of this order through samples whose spans differ by much is
// found badly: what little the samples of the short spans say is carried
// far into the long span beside them, magnified by about the fourth power
// of how much longer it is. Halving one of two spans alike leaves them
// differing by this.
constexpr double balance = 2;

// The spline through points at the parameters `at`: of degree `order` less
// one, or as many fewer as the points are. Each knot between the ends is the
// mean of as many of the parameters in a row as the degree, so that one
// spline goes through the points and stands as near the curve they are
// points of, between them, as its degree lets it.
template <class Spline, class Point>
Handle(Spline) through(const std::vector<Point> &points, const std::vector<double> &at) {
  const int n = static_cast<int>(points.size());
  const int degree = std::min(order - 1, n - 1);
  NCollection_Array1<double> parameters(1, n), flat(1, n + degree + 1);
  NCollection_Array1<int> contact(1, n);
  contact.Init(0);
  NCollection_Array1<Point> poles(1, n);
  for (int k = 0; k < n; ++k) {
    parameters(k + 1) = at[static_cast<size_t>(k)];
    poles(k + 1) = points[static_cast<size_t>(k)];
  }
  for (int j = 1; j <= degree + 1; ++j) {
    flat(j) = at.front();
    flat(n + j) = at.back();
  }
  for (int j = 1; j <= n - degree - 1; ++j) {
    double sum = 0;
    for (int i = j; i < j + degree; ++i)
      sum += at[static_cast<size_t>(i)];
    flat(degree + 1 + j) = sum / degree;
  }
  // OCCT solves for the control points in place of the points.
  int failed = 0;
  BSplCLib::Interpolate(degree, flat, parameters, contact, poles, failed);
  if (failed)
    throw std::runtime_error("cannot fit a contour to its points");
  NCollection_Array1<double> knots(1, BSplCLib::KnotsLength(flat));
  NCollection_Array1<int> mults(1, knots.Length());
  BSplCLib::Knots(flat, knots, mults);
  return new Spline(poles, knots, mults, degree);
}

// Gives the samples at singular points their parameters on the face. The
// surface tells none along the degenerated edge there, every one of which
// stands for the point: the contour ends at the one that the curve on the
// face through its other samples leads to at the end's parameter, on the
// edge's curve on the face.
void settle(std::vector<Sample> &samples, const std::vector<double> &at) {
  const size_t lead = samples.front().singular ? 1 : 0, trail = samples.back().singular ? 1 : 0;
  if (lead + trail == 0 || samples.size() <= lead + trail)
    return;
  std::vector<gp_Pnt2d> others;
  for (size_t k = lead; k + trail < samples.size(); ++k)
    others.push_back(samples[k].uv);
  Handle(Geom2d_BSplineCurve) led;
  if (others.size() > 1)
    led = through<Geom2d_BSplineCurve, gp_Pnt2d>(others, {at.begin() + static_cast<std::ptrdiff_t>(lead),
                                                          at.end() - static_cast<std::ptrdiff_t>(trail)});
  const auto end = [&](Sample &sample, double t) {
    const gp_Pnt2d reached = led.IsNull() ? others.front() : led->Value(t);
    const Singular &point = *sample.singular;
    const Geom2dAPI_ProjectPointOnCurve onto(reached, point.arc, point.first, point.last);
    const gp_Pnt2d a = point.arc->Value(point.first), b = point.arc->Value(point.last);
    sample.uv = reached.Distance(a) <= reached.Distance(b) ? a : b;
    if (onto.NbPoints() && onto.LowerDistance() < reached.Distance(sample.uv))
      sample.uv = onto.NearestPoint();
  };
  if (lead)
    end(samples.front(), at.front());
  if (trail)
    end(samples.back(), at.back());
}

// The curve on the face through the samples at the parameters `at`.
Handle(Geom2d_BSplineCurve) onFace(std::vector<Sample> &samples, const std::vector<double> &at) {
  settle(samples, at);
  std::vector<gp_Pnt2d> uvs;
  for (const auto &sample : samples)
    uvs.push_back(sample.uv);
  return through<Geom2d_BSplineCurve, gp_Pnt2d>(uvs, at);
}

// The space curve through the samples at the parameters `at`.
Handle(Geom_BSplineCurve) inSpace(const std::vector<Sample> &samples, const std::vector<double> &at) {
  std::vector<gp_Pnt> points;
  for (const auto &sample : samples)
    points.push_back(sample.p);
  return through<Geom_BSplineCurve, gp_Pnt>(points, at);
}

// The parameters of samples along the chords between them, from the first.
std::vector<double> chordsOf(const std::vector<Sample> &samples) {
  std::vector<double> chords(samples.size(), 0.0);
  for (size_t k = 1; k < samples.size(); ++k)
    chords[k] = chords[k - 1] + samples[k].p.Distance(samples[k - 1].p);
  return chords;
}

// The splines through the samples over the contour's own length, as OCCT
// integrates the speed of the space curve through them over their chords,
// span by span: along its length the contour is as smooth as it is, however
// its samples are spaced, and the splines come as near it as their degree
// lets them.
Fit interpolate(std::vector<Sample> &samples) {
  const std::vector<double> chords = chordsOf(samples);
  const GeomAdaptor_Curve along(inSpace(samples, chords));
  const std::function<double(double)> speedAt = [&](double t) {
    gp_Pnt p;
    gp_Vec d;
    along.D1(t, p, d);
    return d.Magnitude();
  };
  Scalar speed(speedAt);
  Fit fit;
  fit.at.assign(samples.size(), 0.0);
  for (size_t k = 1; k < samples.size(); ++k) {
    const math_GaussSingleIntegration length(speed, chords[k - 1], chords[k], order);
    if (!length.IsDone())
      throw std::runtime_error("cannot measure a contour's length");
    fit.at[k] = fit.at[k - 1] + length.Value();
  }
  fit.curve = inSpace(samples, fit.at);
  fit.curve2d = onFace(samples, fit.at);
  return fit;
}

// Marks the spans to halve along with those marked, so that halving leaves
// no span more than `balance` times a span next to it: a span next to one
// that is halved is halved too where it is that much longer than the half.
// `at` are the samples' parameters.
void spread(std::vector<bool> &halve, const std::vector<double> &at) {
  for (bool changed = true; changed;) {
    changed = false;
    for (size_t k = 0; k < halve.size(); ++k) {
      if (!halve[k])
        continue;
      const double half = (at[k + 1] - at[k]) / 2;
      for (const size_t j : {k - 1, k + 1})
        if (j < halve.size() && !halve[j] && at[j + 1] - at[j] > balance * half) {
          halve[j] = true;
          changed = true;
        }
    }
  }
}

// A function for OCCT's minimizers that fails where its value cannot be had,
// giving there the largest value it can take, nil, which no minimizer
// keeps: OCCT's particle swarm reads the value whether or not it fails.
class Partial : public math_Function {
public:
  explicit Partial(const std::function<std::optional<double>(double)> &value) : value(value) {}
  bool Value(double s, double &f) override {
    const auto v = value(s);
    f = v.value_or(0.0);
    return v.has_value();
  }

private:
  const std::function<std::optional<double>(double)> &value;
};

// The same function for OCCT's particle swarm, which takes a vector.
class PartialMV : public math_MultipleVarFunction {
public:
  explicit PartialMV(Partial &function) : function(function) {}
  int NbVariables() const override { return 1; }
  bool Value(const math_Vector &x, double &f) override { return function.Value(x(1), f); }

private:
  Partial &function;
};

// How far a curve stands from the contour, measured at the contour points
// that Newton's method reaches from a curve on the face over the same
// parameters, which leads the curve there: `distance` tells how far the
// curve stands from such a point, at a parameter.
class Deviation {
public:
  // How far the curve stands from the contour point at a parameter, and how
  // far that point may stand from the contour, in space: as far as rounding
  // leaves the function vanishing about it.
  struct Point {
    double t, away, blurred;
  };
  Deviation(Handle(Geom2d_Curve) leading, const OnContour &onContour,
            std::function<double(const gp_Pnt &, double)> distance)
      : leading(std::move(leading)), onContour(onContour), distance(std::move(distance)) {}

  // The measure at a parameter, Newton's method moving no farther than
  // `limit`; none where it does not reach the contour.
  std::optional<Point> at(double t, double limit) const {
    const auto reached = onContour(leading.Value(t), limit);
    if (!reached)
      return std::nullopt;
    gp_Pnt p;
    gp_Vec du, dv;
    onContour.surfaceD1(reached->uv.X(), reached->uv.Y(), p, du, dv);
    return Point{t, distance(p, t), reached->blur * stretch(du, dv)};
  }

  // The measure where the curve stands farthest from the contour between
  // `first` and `last`, of a curve whose parameters run over `range`, as
  // OCCT finds where a curve stands farthest from a chord over an interval
  // (GCPnts_TangentialDeflection::EstimDefl, OCCT 8.0.1,
  // src/ModelingData/TKGeomBase/GCPnts/GCPnts_TangentialDeflection.cxx,
  // lines 961-1010), the function the negated square of the distance as
  // GCPnts_DistFunction takes it: Brent's method from the interval's ends
  // and middle to the relative tolerance sqrt(eps) (R. P. Brent, Algorithms
  // for Minimization without Derivatives, Prentice-Hall 1973, ch. 5; Press
  // et al., Numerical Recipes, §10.3), with OCCT's default limit of 100
  // iterations and ZEPS of 1e-12 (math_BrentMinimum.hxx, lines 39-40);
  // where that does not converge, OCCT's particle swarm over the interval,
  // its steps the larger of a tenth of the curve's range and 100 UTol
  // (UTol = 1e-9, GCPnts_TangentialDeflection.hxx, line 81), max(8, 32
  // (U2 - U1) / range) particles (lines 984-994), and Brent's method again
  // about the best it finds (lines 997-1000). None where Newton's method
  // reaches no contour point at a parameter measured: the deviation there
  // is unknown. Once a point proves the span exceeds Confusion + blurred,
  // refinement stops early because the span will be halved anyway; every
  // passing span still runs Brent (and PSO if needed) to sqrt(eps).
  std::optional<Point> farthest(double first, double last, double limit, double range) const {
    const double mid = (first + last) / 2.;
    const auto middle = at(mid, limit);
    if (!middle)
      return std::nullopt;
    if (middle->away > Precision::Confusion() + middle->blurred)
      return *middle;
    std::optional<Point> worst = *middle;
    bool unknown = false, far = false;
    const std::function<std::optional<double>(double)> nearness = [&](double t) -> std::optional<double> {
      if (unknown || far)
        return std::nullopt;
      const auto point = at(t, limit);
      if (!point) {
        unknown = true;
        return std::nullopt;
      }
      if (point->away > worst->away)
        worst = *point;
      if (point->away > Precision::Confusion() + point->blurred) {
        far = true;
        worst = *point;
        return std::nullopt;
      }
      return -point->away * point->away;
    };
    Partial function(nearness);
    static const double tol = std::sqrt(std::numeric_limits<double>::epsilon());
    math_BrentMinimum search(tol, -middle->away * middle->away);
    search.Perform(function, first, mid, last);
    if (unknown)
      return std::nullopt;
    if (far || search.IsDone())
      return worst;
    constexpr double utol = 1.0e-9;
    math_Vector low(1, 1), high(1, 1), steps(1, 1), best(1, 1);
    steps(1) = std::max(0.1 * range, 100. * utol);
    low(1) = first;
    high(1) = last;
    PartialMV swarmed(function);
    double value = 0.0;
    math_PSO swarm(&swarmed, low, high, steps, std::max(8, RealToInt(32 * (last - first) / range)));
    swarm.Perform(steps, value, best);
    if (unknown)
      return std::nullopt;
    if (far)
      return worst;
    math_BrentMinimum refine(tol);
    refine.Perform(function, std::max(best(1) - steps(1), first), best(1), std::min(best(1) + steps(1), last));
    if (unknown)
      return std::nullopt;
    return worst;
  }

private:
  Geom2dAdaptor_Curve leading;
  const OnContour &onContour;
  std::function<double(const gp_Pnt &, double)> distance;
};

// A curve measured against the contour over the spans between samples,
// at the parameters `at`: which spans it stands farther along than what
// OCCT tells apart, beyond how far the points measured may stand from the
// contour, as each span is measured where it stands farthest; and the
// tolerance it keeps over all of them, at least what OCCT tells apart.
struct Measured {
  std::vector<bool> far;
  double tolerance;
};
Measured measure(const Deviation &deviation, const std::vector<Sample> &samples, const std::vector<double> &at,
                 bool stopOnFirstFar = false) {
  const size_t spans = samples.size() - 1;
  Measured measured{std::vector<bool>(spans), Precision::Confusion()};
  for (size_t k = 0; k < spans; ++k) {
    // Newton's method goes no farther from a point of a span than half the
    // span is long.
    const auto worst = deviation.farthest(at[k], at[k + 1], samples[k].uv.Distance(samples[k + 1].uv) / 2,
                                          at.back() - at.front());
    measured.far[k] = !worst || worst->away > Precision::Confusion() + worst->blurred;
    if (measured.far[k] && stopOnFirstFar)
      return measured;
    if (worst)
      measured.tolerance = std::max(measured.tolerance, worst->away + worst->blurred);
  }
  return measured;
}
} // namespace

// Fits a contour to its samples, halving each span along which `measure`
// finds the space curve standing farther from the contour than OCCT tells
// apart; and with it the spans beside it that halving it would leave too
// long. A span is halved at the contour point `locate` finds halfway along
// the traced contour between its samples. A span shorter than OCCT tells
// apart that is still to be halved is no contour that fitting can follow.
Fit fitContour(std::vector<Sample> samples, const Handle(Geom_Surface) &, const OnContour &onContour,
               const std::function<Sample(double)> &locate) {
  for (;;) {
    Fit fit = interpolate(samples);
    const GeomAdaptor_Curve curve(fit.curve);
    const Deviation deviation(fit.curve2d, onContour,
                              [&curve](const gp_Pnt &p, double t) { return curve.Value(t).Distance(p); });
    Measured measured = measure(deviation, samples, fit.at);
    auto &halve = measured.far;
    if (std::find(halve.begin(), halve.end(), true) == halve.end()) {
      fit.tolerance = measured.tolerance;
      return fit;
    }
    spread(halve, fit.at);
    std::vector<Sample> next;
    next.reserve(samples.size() + static_cast<size_t>(std::count(halve.begin(), halve.end(), true)));
    next.push_back(samples.front());
    for (size_t k = 0; k < halve.size(); ++k) {
      if (halve[k]) {
        if (samples[k].p.Distance(samples[k + 1].p) <= Precision::Confusion())
          throw std::runtime_error("cannot fit a contour to its points");
        next.push_back(locate((samples[k].along + samples[k + 1].along) / 2));
      }
      next.push_back(samples[k + 1]);
    }
    samples.swap(next);
  }
}

namespace {
// The line or the circle that the points of a contour lie on, each within
// `allowed` of it: the line through the first and the last point, or else
// the circle OCCT finds through the first, the middle and the last point,
// or through the first and the points a third and two thirds of the way
// where the last comes back to the first. The line runs from the first
// point to the last; the circle, so too, the way the middle point lies, or
// all round from the first point back to it; with how far the points stand
// from it, and how far it stands from a point. None where the points lie
// on neither.
struct Through {
  Exact exact;
  double off;
  std::function<double(const gp_Pnt &)> distance;
};
std::optional<Through> throughPoints(const std::vector<Sample> &points,
                                     const std::function<double(const Sample &)> &allowed) {
  const size_t n = points.size();
  if (n < 3)
    return std::nullopt;
  double off = 0;
  const auto within = [&](const auto &distance) {
    off = 0;
    for (const auto &point : points) {
      const double d = distance(point.p);
      if (!(d <= allowed(point)))
        return false;
      off = std::max(off, d);
    }
    return true;
  };
  const gp_Pnt &a = points.front().p, &b = points.back().p;
  const bool round = a.Distance(b) <= Precision::Confusion();
  if (!round) {
    const gp_Lin line(a, gp_Dir(gp_Vec(a, b)));
    const auto toLine = [line](const gp_Pnt &p) { return line.Distance(p); };
    if (within(toLine))
      return Through{Exact{new Geom_Line(line), 0, a.Distance(b), 0}, off, toLine};
  }
  gp_Circ circ;
  if (!GeomConvert_CurveToAnaCurve::GetCircle(circ, a, points[round ? n / 3 : n / 2].p, round ? points[2 * n / 3].p : b))
    return std::nullopt;
  const auto toCircle = [circ](const gp_Pnt &p) { return circ.Distance(p); };
  if (!within(toCircle))
    return std::nullopt;
  const Handle(Geom_Circle) circle = new Geom_Circle(circ);
  const auto from = [&](const gp_Pnt &p, double start) {
    return ElCLib::InPeriod(ElCLib::Parameter(circle->Circ(), p), start, start + 2 * M_PI);
  };
  double first = ElCLib::Parameter(circle->Circ(), a);
  if (round)
    return Through{Exact{circle, first, first + 2 * M_PI, 0}, off, toCircle};
  if (from(points[n / 2].p, first) > from(b, first)) {
    circle->Reverse();
    first = ElCLib::Parameter(circle->Circ(), a);
  }
  return Through{Exact{circle, first, from(b, first), 0}, off, toCircle};
}
} // namespace

// A contour that a line or a circle stands for is that curve: where the
// samples lie on it within what OCCT tells apart, beyond where rounding
// leaves the contour, and so does the contour between them, as `measure`
// finds it from the curve on the face through the samples. Its tolerance is
// the most measured, at least how far the samples stand from it.
std::optional<Exact> exactCurve(const std::vector<Sample> &samples, const Handle(Geom_Surface) &,
                                const OnContour &onContour) {
  const auto allowed = [&](const Sample &sample) {
    const double blur = onContour.blur(sample.uv);
    gp_Pnt p;
    gp_Vec du, dv;
    onContour.surfaceD1(sample.uv.X(), sample.uv.Y(), p, du, dv);
    return Precision::Confusion() + blur * stretch(du, dv);
  };
  auto through = throughPoints(samples, allowed);
  if (!through)
    return std::nullopt;
  std::vector<Sample> settled = samples;
  const std::vector<double> at = chordsOf(settled);
  const Deviation deviation(onFace(settled, at), onContour,
                            [&](const gp_Pnt &p, double) { return through->distance(p); });
  const Measured measured = measure(deviation, settled, at, true);
  if (std::find(measured.far.begin(), measured.far.end(), true) != measured.far.end())
    return std::nullopt;
  through->exact.tolerance = std::max(measured.tolerance, through->off);
  return through->exact;
}
} // namespace huak::space::contour
