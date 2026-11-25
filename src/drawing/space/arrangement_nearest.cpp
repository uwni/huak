// How far a point stands from a part of an image.
#include "arranging.hxx"

namespace huak::space {
// The part of an image without a turn on one side of a parameter: from it
// to the image's next turn that way, or its end, and back to the turn
// before, or the parameter itself where the image turns there.
Arranging::Span Arranging::spanOf(size_t k, double t, int way) const {
  const auto &image = images[k];
  Span span{image.first, image.last};
  for (const double turn : image.turns) {
    const bool before = way > 0 ? turn <= t + Precision::PConfusion() : turn < t - Precision::PConfusion();
    if (before) {
      span.lo = turn;
    } else {
      span.hi = turn;
      break;
    }
  }
  return span;
}

bool Arranging::turnsAt(size_t k, double t) const {
  const auto &turns = images[k].turns;
  return std::any_of(turns.begin(), turns.end(), [&](double turn) { return std::abs(turn - t) <= Precision::PConfusion(); });
}

// The segment of an image's polyline that holds a parameter.
size_t Arranging::segmentAt(size_t k, double t) const {
  const auto &at = images[k].at;
  const size_t n = static_cast<size_t>(std::upper_bound(at.begin(), at.end(), t) - at.begin());
  return n == 0 ? 0 : std::min(n - 1, at.size() - 2);
}

// The segments of an image's polyline over a part of its range.
std::pair<size_t, size_t> Arranging::segmentsOver(size_t k, double lo, double hi) const {
  const size_t from = segmentAt(k, lo);
  size_t to = segmentAt(k, hi);
  if (to > from && images[k].at[to] >= hi - Precision::PConfusion())
    --to;
  return {from, to};
}

// How far a point stands from the part of an image over segments
// `from`..`to` of its polyline, as far as they lie within [lo, hi], and
// the image's parameter there. Each segment's part stands no nearer than
// its chord, less what the image may stand from the chord, and no
// farther than its ends; the image stands nearest within a part whose
// bound allows it no farther than the nearest of those ends: there, at an
// end of the part or where OCCT's minimizer finds it nearest between
// them.
std::pair<double, double> Arranging::nearestOver(const gp_Pnt2d &p, size_t k, size_t from, size_t to,
                                                 double lo, double hi) const {
  const auto &image = images[k];
  std::pair<double, double> best{RealLast(), std::clamp(image.at[from], lo, hi)};
  const auto part = [&](size_t m) { return std::pair{std::max(image.at[m], lo), std::min(image.at[m + 1], hi)}; };
  // A whole segment, over which the image goes one way, stands no
  // farther than its chord and what it may stand from it.
  double most = RealLast();
  for (size_t m = from; m <= to; ++m) {
    const auto [a, b] = part(m);
    if (a > b)
      continue;
    if (a == image.at[m] && b == image.at[m + 1])
      most = std::min(most, apart(p, image.points[m], image.points[m + 1]) + image.offs[m]);
    for (const double end : {a, b}) {
      // A polyline point is the image's own point there.
      const gp_Pnt2d there = end == image.at[m] ? image.points[m] : end == image.at[m + 1] ? image.points[m + 1] : at(k, end);
      if (const double d = there.Distance(p); d < best.first)
        best = {d, end};
    }
  }
  most = std::min(most, best.first);
  for (size_t m = from; m <= to; ++m) {
    const auto [a, b] = part(m);
    if (!(a < b) || apart(p, image.points[m], image.points[m + 1]) - image.offs[m] > most)
      continue;
    const double seed = std::clamp(image.at[m] + (image.at[m + 1] - image.at[m]) * along(p, image.points[m], image.points[m + 1]), a, b);
    // Between the segment's ends the image goes one way and turns
    // little: it comes nearest once, wherever it may slow down.
    const std::function<double(double)> away = [&](double s) { return image.adaptor->Value(s).SquareDistance(p); };
    Scalar function(away);
    math_BrentMinimum between(Precision::PConfusion());
    between.Perform(function, a, seed, b);
    if (between.IsDone())
      if (const double d = std::sqrt(between.Minimum()); d < best.first)
        best = {d, between.Location()};
  }
  return best;
}

// How far a point stands from the part of an image between two of its
// parameters, and the image's parameter there: over all of the part, or,
// from `seed`, where the image stands nearest next to that parameter:
// within as many segments of its polyline about it, two and twice as many
// again, as hold that place clear of the outermost.
std::pair<double, double> Arranging::nearest(const gp_Pnt2d &p, size_t k, double lo, double hi, const double *seed) const {
  const auto &image = images[k];
  const auto [from, to] = segmentsOver(k, lo, hi);
  if (!seed)
    return nearestOver(p, k, from, to, lo, hi);
  const size_t n = std::clamp(segmentAt(k, *seed), from, to);
  for (size_t about = 2;; about *= 2) {
    const size_t first = std::max(from, n >= about ? n - about : 0), last = std::min(to, n + about);
    const auto found = nearestOver(p, k, first, last, lo, hi);
    if ((first == from || found.second > image.at[first + 1]) && (last == to || found.second < image.at[last]))
      return found;
  }
}

// Whether an image stays within `r` of a point between two of its
// parameters: every control point of its pieces there does, the image
// staying within their convex hull.
bool Arranging::staysWithin(size_t k, double a, double b, const gp_Pnt2d &centre, double r) const {
  if (a > b)
    std::swap(a, b);
  if (at(k, a).Distance(centre) > r || at(k, b).Distance(centre) > r)
    return false;
  bool within = true;
  hullOver(k, a, b, [&](const NCollection_Array1<gp_Pnt2d> &poles) {
    for (int j = poles.Lower(); j <= poles.Upper() && within; ++j)
      within = poles(j).Distance(centre) <= r;
  });
  return within;
}

// Whether an image stays within a vertex between two of its parameters.
bool Arranging::within(size_t k, double lo, double hi, size_t vertex) const {
  return staysWithin(k, lo, hi, meets[vertex].at, meets[vertex].reach);
}
} // namespace huak::space
