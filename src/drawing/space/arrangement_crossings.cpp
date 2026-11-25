// Where two images meet or cross, found by halving their parts.
#include "arranging.hxx"

namespace huak::space {
// Whether two images are known to meet where they pass a point at their
// parameters `u` and `w`: within a vertex that cuts both, or along a
// stretch of the two.
bool Arranging::settled(size_t i, double u, size_t j, double w) const {
  const gp_Pnt2d p = at(i, u), q = at(j, w);
  for (const auto &cut : images[i].cuts) {
    const auto &meet = meets[standing(cut.vertex)];
    if (meet.at.Distance(p) > meet.reach + images[i].blur || meet.at.Distance(q) > meet.reach + images[j].blur)
      continue;
    if (std::any_of(meet.through.begin(), meet.through.end(), [&](const Passage &passage) { return passage.image == j; }))
      return true;
  }
  for (const size_t n : stretchesOf[i]) {
    const auto &s = stretches[n];
    if (s.tool == i && s.other == j && s.first <= u && u <= s.last && s.from <= w && w <= s.to)
      return true;
    if (s.tool == j && s.other == i && s.first <= w && w <= s.last && s.from <= u && u <= s.to)
      return true;
  }
  return false;
}

// The nodes of the two halves of a node of an image, halved when first
// asked for.
std::pair<size_t, size_t> Arranging::halves(size_t k, size_t node) {
  auto &nodes = images[k].nodes;
  if (nodes[node].halves == 0) {
    const Part part = nodes[node].part;
    const double middle = (part.first + part.last) / 2;
    const gp_Pnt2d m = at(k, middle);
    nodes[node].halves = nodes.size();
    nodes.push_back({{part.first, middle, part.from, m, hullOf(k, part.first, middle, part.from, m)}});
    nodes.push_back({{middle, part.last, m, part.to, hullOf(k, middle, part.last, m, part.to)}});
  }
  return {nodes[node].halves, nodes[node].halves + 1};
}

// Whether two parts of images meet only as they are already known to:
// both lie within a stretch along which the two run, or within the reach
// of a vertex that both pass through.
bool Arranging::related(size_t i, const Part &a, size_t j, const Part &b) const {
  const double near = Precision::PConfusion();
  for (const size_t n : stretchesOf[i]) {
    const auto &s = stretches[n];
    if (s.tool == i && s.other == j && s.first - near <= a.first && a.last <= s.last + near && s.from - near <= b.first &&
        b.last <= s.to + near)
      return true;
    if (s.tool == j && s.other == i && s.from - near <= a.first && a.last <= s.to + near && s.first - near <= b.first &&
        b.last <= s.last + near)
      return true;
  }
  // The cut before the part, those within it, and the one after.
  const auto &cuts = images[i].cuts;
  auto cut = std::lower_bound(cuts.begin(), cuts.end(), a.first, [](const Cut &c, double at) { return c.at < at; });
  if (cut != cuts.begin())
    --cut;
  for (; cut != cuts.end(); ++cut) {
    const auto &meet = meets[standing(cut->vertex)];
    const auto within = [&](const gp_Pnt2d &p) { return meet.at.Distance(p) <= meet.reach; };
    if (within(a.from) && within(a.to) && within(b.from) && within(b.to) &&
        std::any_of(meet.through.begin(), meet.through.end(), [&](const Passage &passage) { return passage.image == j; }))
      return true;
    if (cut->at > a.last)
      break;
  }
  return false;
}

// Two images meet where they pass a point at their parameters `u` and
// `w`, unless they are known to: at the vertex that reaches the point, or
// at a new one.
void Arranging::meetAt(size_t i, double u, size_t j, double w) {
  if (settled(i, u, j, w))
    return;
  const gp_Pnt2d p = at(i, u);
  const double within = images[i].blur + images[j].blur + p.Distance(at(j, w)) + Precision::Confusion();
  size_t vertex = meets.size();
  for (size_t v = 0; v < meets.size() && vertex == meets.size(); ++v)
    if (meets[v].same == v && meets[v].at.Distance(p) <= meets[v].reach + within)
      vertex = v;
  if (vertex == meets.size())
    vertex = vertexAt(p, within);
  pass(i, u, vertex);
  pass(j, w, vertex);
}

// Whether two parts of images head apart: each heads within less than a
// right angle of its chord, and every way one heads stands farther,
// either way, from every way the other heads than none.
bool Arranging::headApart(const Part &a, const Part &b) {
  if (!a.hull.headed || !b.hull.headed)
    return false;
  const gp_Vec2d mine(a.from, a.to), theirs(b.from, b.to);
  const double heading = std::atan2(mine.Y(), mine.X()) + (a.hull.low + a.hull.high) / 2;
  const double theirHeading = std::atan2(theirs.Y(), theirs.X()) + (b.hull.low + b.hull.high) / 2;
  return std::abs(std::remainder(heading - theirHeading, M_PI)) >
         (a.hull.high - a.hull.low) / 2 + (b.hull.high - b.hull.low) / 2;
}

// How far a point stands from the box that holds a part of an image
// heading within a right angle of its chord: as long as the chord, and
// as wide either way as the part may stand from it. None within.
double Arranging::beyond(const gp_Pnt2d &p, const Part &part) {
  const gp_Vec2d chord(part.from, part.to), to(part.from, p);
  const double length = chord.Magnitude();
  const double along = to.Dot(chord) / length, across = std::abs(chord.Crossed(to)) / length;
  return std::hypot(std::max({0.0, -along, along - length}), std::max(0.0, across - part.hull.off));
}

// How many times the difference between a point of one part and a point
// of another turns about none, from the one's start less the other's,
// as the first runs to its end, the second to its, the first back to its
// start and the second back to its: as the four differences between
// their ends tell, each way round turning less than a half turn.
int Arranging::winding(const Part &a, const Part &b) {
  const std::array<gp_Vec2d, 4> ends{gp_Vec2d(b.from, a.from), gp_Vec2d(b.from, a.to), gp_Vec2d(b.to, a.to),
                                     gp_Vec2d(b.to, a.from)};
  double turned = 0;
  for (size_t n = 0; n < ends.size(); ++n) {
    const gp_Vec2d &p = ends[n], &q = ends[(n + 1) % ends.size()];
    turned += std::atan2(p.Crossed(q), p.Dot(q));
  }
  return static_cast<int>(std::lround(turned / (2 * M_PI)));
}

// Makes two parts of images meet where they do, unless they are known
// to.
//
// Each part stands within its hull's `off` of its chord. Parts whose
// chords stand farther apart than that and what tells the images apart do
// not meet.
//
// A part that heads within a right angle of its chord stands within the
// box along the chord as wide either way as its `off`. Where two such
// parts head apart, the difference between a point of one and a point of
// the other turns the same way however the points run along their parts:
// the parts cross as many times as the difference turns about none as
// the points run round the parts' ends in turn, `winding`; and nowhere
// but where they cross does the difference stand still, so that, where
// they do not cross, they come nearest each other at an end of one. Where
// the ends of each part stand clear of the other's box, the difference
// keeps to one side of none along each way round, and the four
// differences between the ends tell how far it turns. Then where the
// parts do not cross and no end comes within what tells the images apart
// of the other's box, they do not meet; where they cross, they cross
// once, where OCCT's search from where the chords come nearest finds,
// unless it strays out of the parts.
//
// Parts that stand no farther from their chords than half of what tells
// the images apart come within about that of each other where the chords
// do: there, where each image stands nearest its chord's place, they
// touch, cross, or run along each other, and how far, `relate` tells
// from there. Otherwise the part that may reach the farther across is
// halved, and each half taken with the other part; a part that spans no
// more of its range than OCCT tells apart is not halved, and parts
// neither of which is are points of their images that meet.
void Arranging::resolve(size_t i, size_t node, size_t j, size_t theirNode) {
  const Part a = images[i].nodes[node].part, b = images[j].nodes[theirNode].part;
  const double told = images[i].blur + images[j].blur + Precision::Confusion();
  if (apart(a.from, a.to, b.from, b.to) > a.hull.off + b.hull.off + told)
    return;
  if (related(i, a, j, b))
    return;
  const gp_Vec2d mine(a.from, a.to), theirs(b.from, b.to);
  const auto [s, r] = nearestAlong(a.from, a.to, b.from, b.to);
  if (headApart(a, b)) {
    const double clear = std::min({beyond(b.from, a), beyond(b.to, a), beyond(a.from, b), beyond(a.to, b)});
    const int crossings = clear > told ? std::abs(winding(a, b)) : -1;
    if (crossings == 0) {
      return;
    }
    if (crossings == 1) {
      const double u = a.first + s * (a.last - a.first), w = b.first + r * (b.last - b.first);
      const Extrema_LocateExtCC2d local(*images[i].adaptor, *images[j].adaptor, u, w);
      if (local.IsDone() && local.SquareDistance() <= Precision::SquareConfusion()) {
        Extrema_POnCurv2d here, there;
        local.Point(here, there);
        const double near = Precision::PConfusion();
        if (here.Parameter() >= a.first - near && here.Parameter() <= a.last + near &&
            there.Parameter() >= b.first - near && there.Parameter() <= b.last + near) {
          meetAt(i, here.Parameter(), j, there.Parameter());
          return;
        }
      }
    }
  }
  const bool mineHalves = a.last - a.first > Precision::PConfusion(),
             theirsHalve = b.last - b.first > Precision::PConfusion();
  if (a.hull.off + b.hull.off <= told / 2 || (!mineHalves && !theirsHalve)) {
    // Where each image stands nearest the place on its chord where the
    // chords come nearest: an image's parameter need not run in step with
    // its chord, as where it slows down.
    const gp_Pnt2d p = a.from.Translated(mine * s), q = b.from.Translated(theirs * r);
    meetAt(i, nearest(p, i, a.first, a.last).second, j, nearest(q, j, b.first, b.last).second);
    return;
  }
  if (mineHalves && (!theirsHalve || a.size() >= b.size())) {
    const auto [left, right] = halves(i, node);
    resolve(i, left, j, theirNode);
    resolve(i, right, j, theirNode);
  } else {
    const auto [left, right] = halves(j, theirNode);
    resolve(i, node, j, left);
    resolve(i, node, j, right);
  }
}

// The images that cross or touch in the plane meet where they do: each
// segment of one's polyline with each of another's, and with each of its
// own but the next, which it meets at the point between them. Where an
// image turns back, the parts beside the turn were related as it was cut
// there.
void Arranging::cross() {
  for (size_t i = 0; i < images.size(); ++i)
    for (size_t j = i; j < images.size(); ++j) {
      const auto &one = images[i], &other = images[j];
      if (one.box.IsOut(other.box))
        continue;
      const double told = one.blur + other.blur + Precision::Confusion();
      for (size_t a = 0; a + 1 < one.at.size(); ++a) {
        Bnd_B2<double> about;
        about.Add(one.points[a].XY());
        about.Add(one.points[a + 1].XY());
        about.Enlarge(one.offs[a] + told);
        if (about.IsOut(other.box))
          continue;
        for (size_t b = i == j ? a + 2 : 0; b + 1 < other.at.size(); ++b) {
          Bnd_B2<double> theirs;
          theirs.Add(other.points[b].XY());
          theirs.Add(other.points[b + 1].XY());
          theirs.Enlarge(other.offs[b]);
          if (!about.IsOut(theirs))
            resolve(i, a, j, b);
        }
      }
    }
}
} // namespace huak::space
