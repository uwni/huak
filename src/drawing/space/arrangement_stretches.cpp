// Images that run along each other within tolerance.
#include "arranging.hxx"

namespace huak::space {
Arranging::Run Arranging::runsAlong(size_t k, double t, int way, double room, size_t other, double seed, const Span &along) const {
  const auto &image = images[k];
  const double allowed = lingering * (image.blur + images[other].blur);
  const gp_Pnt2d start = at(k, t);
  const double from = nearest(start, other, along.lo, along.hi, &seed).second;
  if (start.Distance(at(other, from)) > allowed)
    return {0.0, from, from, 0.0};
  // A part of an image as a band about its chord: its ends, how far it
  // may stand from the chord, and whether every step between its control
  // points heads within a right angle of the chord, so that it heads so
  // all along.
  struct Band {
    gp_Pnt2d from, to;
    double off;
    bool headed;
  };
  const auto bandOf = [&](size_t n, double a, double b) {
    if (a > b)
      std::swap(a, b);
    Band band{at(n, a), at(n, b), 0, false};
    const gp_Vec2d chord(band.from, band.to);
    band.headed = chord.SquareMagnitude() > 0;
    hullOver(n, a, b, [&](const NCollection_Array1<gp_Pnt2d> &poles) {
      for (int j = poles.Lower(); j <= poles.Upper(); ++j) {
        band.off = std::max(band.off, apart(poles(j), band.from, band.to));
        if (j == poles.Lower())
          continue;
        const gp_Vec2d step(poles(j - 1), poles(j));
        if (step.SquareMagnitude() > 0 && !(step.Dot(chord) > 0))
          band.headed = false;
      }
    });
    return band;
  };
  const auto reaches = [](const Band &one, const Band &two) {
    return std::max(apart(one.from, two.from, two.to), apart(one.to, two.from, two.to)) + one.off + two.off;
  };
  // The other's parameter nearest the image's point s on, found from `near`.
  const auto besideAt = [&](double s, double near) {
    return nearest(at(k, t + way * s), other, along.lo, along.hi, &near).second;
  };
  // Whether the image from s to u on and the other from v to w are proven
  // to stand within the tolerance of each other, or proven apart.
  const auto together = [&](double s, double u, double v, double w) {
    const Band mine = bandOf(k, t + way * s, t + way * u), theirs = bandOf(other, v, w);
    return mine.headed && theirs.headed && std::max(reaches(mine, theirs), reaches(theirs, mine)) <= allowed;
  };
  const auto parted = [&](double s, double u, double v, double w) {
    const Band mine = bandOf(k, t + way * s, t + way * u), theirs = bandOf(other, v, w);
    return apart(mine.from, mine.to, theirs.from, theirs.to) - mine.off - theirs.off > allowed;
  };
  // How far from the point the image may come within s of it: no
  // farther than the control points of its hull there.
  const auto farTo = [&](double s) {
    double most = 0;
    hullOver(k, std::min(t, t + way * s), std::max(t, t + way * s), [&](const NCollection_Array1<gp_Pnt2d> &poles) {
      for (int j = poles.Lower(); j <= poles.Upper(); ++j)
        most = std::max(most, poles(j).Distance(start));
    });
    return most;
  };
  double hi = room, scale = room;
  {
    gp_Pnt2d p, q;
    gp_Vec2d mine, bend, theirs, theirBend;
    image.adaptor->D2(t, p, mine, bend);
    images[other].adaptor->D2(from, q, theirs, theirBend);
    const double speed = mine.Magnitude(), theirSpeed = theirs.Magnitude();
    if (speed > gp::Resolution() && theirSpeed > gp::Resolution()) {
      const double sine = std::abs(mine.Crossed(theirs)) / (speed * theirSpeed);
      // How fast each turns as the image runs, and half of how fast
      // they turn apart.
      const double turn = mine.Crossed(bend) / (speed * speed * speed);
      const double theirTurn = (mine.Dot(theirs) < 0 ? -1 : 1) * theirs.Crossed(theirBend) / (theirSpeed * theirSpeed * theirSpeed);
      const double parting = std::abs(turn - theirTurn) / 2;
      // Where sine times the length and parting times its square come to
      // the tolerance, in the form that keeps its digits either way.
      const double reach = sine + std::sqrt(sine * sine + 4 * parting * allowed);
      const double step = reach > 0 ? 2 * allowed / reach / speed : RealLast();
      scale = step;
      // Where from twice that far on to four times they are proven
      // apart, the run ends within twice as far. A meeting no wider than
      // a vertex covers is no run.
      if (4 * step <= room) {
        const double v = besideAt(2 * step, from), w = besideAt(4 * step, v);
        if (parted(2 * step, 4 * step, v, w)) {
          hi = 2 * step;
          if (const double far = farTo(hi); far <= covered * allowed)
            return Run{hi, from, v, far};
        }
      }
    }
  }
  // The first piece: as long as they are about to stand apart over,
  // within the first of the polyline's segments.
  double lo = 0, beside = from, h = std::min(hi, scale);
  for (const double u : image.at)
    if ((u - t) * way > Precision::PConfusion())
      h = std::min(h, (u - t) * way);
  while (lo < hi) {
    const double piece = std::min(h, hi - lo);
    const double w = besideAt(lo + piece, beside);
    if (together(lo, lo + piece, beside, w)) {
      lo += piece;
      beside = w;
      h = 2 * piece;
      continue;
    }
    const double half = lo + piece / 2, v = besideAt(half, beside);
    if (parted(half, lo + piece, v, w)) {
      hi = half;
      h = piece / 2;
      continue;
    }
    if (const Band last = bandOf(k, t + way * lo, t + way * (lo + piece)); last.from.Distance(last.to) + 2 * last.off <= Precision::Confusion()) {
      hi = lo + piece;
      break;
    }
    h = piece / 2;
  }
  return {lo, from, beside, farTo(hi)};
}

// Whether two parts are already known to run along each other from where
// they pass a point, one way along the first: within a stretch of the two
// that goes on that way. A stretch runs from where the two meet to where
// they part; from there they run along each other only back along it.
bool Arranging::running(size_t k, double t, int way, size_t other, double w) const {
  const double near = Precision::PConfusion();
  for (const size_t n : stretchesOf[k]) {
    const auto &s = stretches[n];
    if (s.tool == k && s.other == other && s.first - near <= t && t <= s.last + near && s.from - near <= w &&
        w <= s.to + near && (way > 0 ? s.last - t : t - s.first) > near)
      return true;
    if (s.tool == other && s.other == k && s.from - near <= t && t <= s.to + near && s.first - near <= w &&
        w <= s.last + near && (way > 0 ? s.to - t : t - s.from) > near)
      return true;
  }
  return false;
}

// Two passages go through one vertex, of two images or of one image that
// turns back between them, or one passage where its image turns: each way
// from the vertex, as far as a part of the first runs along a part of the
// other, they part within the vertex, which grows to cover them that far
// on both, or run on along a stretch. A part that goes no farther along
// another than sixteen times the distance that tells them apart parts
// from it rather than runs along it.
void Arranging::relate(size_t vertex, const Passage &one, const Passage &other) {
  const bool ordered = one.image != other.image ? one.image < other.image : one.at <= other.at;
  const Passage &first = ordered ? one : other, &second = ordered ? other : one;
  const size_t k = first.image;
  const double t = first.at;
  const bool self = first.image == second.image && std::abs(first.at - second.at) <= Precision::PConfusion();
  const auto &mine = images[k], &theirs = images[second.image];
  const double told = mine.blur + theirs.blur;
  // The other's parts next to its passage: one, or two where it turns.
  std::vector<Span> beside{spanOf(second.image, second.at, -1)};
  if (const Span after = spanOf(second.image, second.at, 1); !(after == beside.front()))
    beside.push_back(after);
  for (const int way : {-1, 1}) {
    // The two parts next to one passage are related once.
    if (self && way < 0)
      continue;
    const Span span = spanOf(k, t, way);
    const double room = way > 0 ? span.hi - t : t - span.lo;
    if (room <= Precision::PConfusion())
      continue;
    for (const auto &along : beside) {
      // A part of an image runs along no part of itself: only beyond a
      // turn does the image run back.
      if (first.image == second.image && along == span)
        continue;
      if (running(k, t, way, second.image, second.at))
        continue;
      const auto [reach, from, to, far] = runsAlong(k, t, way, room, second.image, second.at, along);
      if (reach <= Precision::PConfusion())
        continue;
      if (far <= covered * lingering * told) {
        grow(vertex, meets[vertex].at.Distance(at(k, t)) + far + lingering * told + std::max(mine.blur, theirs.blur) +
                         Precision::Confusion());
        continue;
      }
      const double end = t + way * reach;
      stretchesOf[k].push_back(stretches.size());
      if (second.image != k)
        stretchesOf[second.image].push_back(stretches.size());
      stretches.push_back({k, std::min(t, end), std::max(t, end), t, second.image, std::min(from, to), std::max(from, to), from});
    }
  }
}

// Along a stretch the two parts are one curve of the plane: where either
// is cut, both are, at one vertex that covers both. False where they
// were.
bool Arranging::join(size_t k, double t, size_t other, double beside) {
  const Cut *here = cutNear(k, t), *there = cutNear(other, beside);
  // Cuts at one vertex are one point of the plane, however far apart
  // within its reach they stand.
  if (here && there && standing(here->vertex) == standing(there->vertex))
    return false;
  const gp_Pnt2d p = at(k, t), q = at(other, beside);
  if (p.Distance(q) > 2 * lingering * (images[k].blur + images[other].blur) + Precision::Confusion())
    throw std::runtime_error("images that run along each other stand apart where one is cut");
  if (here && there) {
    unite(here->vertex, there->vertex);
    return true;
  }
  const size_t vertex = here ? here->vertex : there ? there->vertex : vertexAt(p, images[k].blur + Precision::Confusion());
  pass(k, t, vertex);
  pass(other, beside, vertex);
  return true;
}

// Where one part leaves the other, a stretch ends and is cut; and each
// stretch's two parts are cut alike along it.
bool Arranging::alike() {
  bool cut = false;
  for (; ended < stretches.size(); ++ended) {
    const Stretch s = stretches[ended];
    const bool forward = s.anchor <= (s.first + s.last) / 2, onward = s.beside <= (s.from + s.to) / 2;
    if (join(s.tool, forward ? s.last : s.first, s.other, onward ? s.to : s.from))
      cut = true;
  }
  for (size_t n = 0; n < stretches.size(); ++n) {
    const Stretch s = stretches[n];
    if (s.mine == images[s.tool].cuts.size() && s.theirs == images[s.other].cuts.size())
      continue;
    std::vector<double> mine, theirs;
    for (const auto &c : images[s.tool].cuts)
      if (s.first - Precision::PConfusion() <= c.at && c.at <= s.last + Precision::PConfusion())
        mine.push_back(c.at);
    for (const auto &c : images[s.other].cuts)
      if (s.from - Precision::PConfusion() <= c.at && c.at <= s.to + Precision::PConfusion())
        theirs.push_back(c.at);
    bool joined = false;
    for (const double t : mine) {
      if (join(s.tool, t, s.other, nearest(at(s.tool, t), s.other, s.from, s.to).second))
        joined = true;
    }
    for (const double beside : theirs) {
      if (join(s.tool, nearest(at(s.other, beside), s.tool, s.first, s.last).second, s.other, beside))
        joined = true;
    }
    // Cut alike, unless cutting them cut them again.
    if (!joined) {
      stretches[n].mine = images[s.tool].cuts.size();
      stretches[n].theirs = images[s.other].cuts.size();
    }
    cut = cut || joined;
  }
  return cut;
}
} // namespace huak::space
