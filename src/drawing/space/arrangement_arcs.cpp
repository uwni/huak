// The arcs that come out, with their parts and polylines.
#include "arranging.hxx"

namespace huak::space {
// Each image's pieces between its cuts; the pieces that are one curve of
// the plane, which along a stretch are each piece of the one part and the
// piece of the other beside it, and so on from part to part; and for each
// piece the first of those it is one with. False where cuts at one place
// of an image were at two vertices, which then are one.
bool Arranging::divide() {
  bool same = true;
  for (auto &image : images)
    for (size_t i = 0; i + 1 < image.cuts.size(); ++i)
      if (image.cuts[i + 1].at - image.cuts[i].at <= Precision::PConfusion() &&
          standing(image.cuts[i].vertex) != standing(image.cuts[i + 1].vertex)) {
        unite(image.cuts[i].vertex, image.cuts[i + 1].vertex);
        same = false;
      }
  if (!same)
    return false;
  pieces.clear();
  piecesOf.assign(images.size(), {});
  for (size_t k = 0; k < images.size(); ++k) {
    piecesOf[k].first = pieces.size();
    const auto &cuts = images[k].cuts;
    for (size_t i = 0; i + 1 < cuts.size(); ++i) {
      if (cuts[i + 1].at - cuts[i].at <= Precision::PConfusion())
        continue;
      const size_t from = standing(cuts[i].vertex), to = standing(cuts[i + 1].vertex);
      // What stays within one vertex is that point.
      if (from == to && within(k, cuts[i].at, cuts[i + 1].at, from))
        continue;
      pieces.push_back({k, cuts[i].at, cuts[i + 1].at, from, to});
    }
    piecesOf[k].second = pieces.size();
  }
  bundle.resize(pieces.size());
  for (size_t i = 0; i < bundle.size(); ++i)
    bundle[i] = i;
  for (const auto &s : stretches)
    for (size_t i = piecesOf[s.tool].first; i < piecesOf[s.tool].second; ++i) {
      const double middle = (pieces[i].lo + pieces[i].hi) / 2;
      if (middle < s.first || s.last < middle)
        continue;
      const double beside = nearest(at(s.tool, middle), s.other, s.from, s.to).second;
      for (size_t j = piecesOf[s.other].first; j < piecesOf[s.other].second; ++j)
        if (pieces[j].lo <= beside && beside <= pieces[j].hi) {
          const size_t one = bundleOf(i), other = bundleOf(j);
          bundle[std::max(one, other)] = std::min(one, other);
          break;
        }
    }
  bundles.clear();
  for (size_t i = 0; i < pieces.size(); ++i)
    bundles[bundleOf(i)].push_back(i);
  return true;
}

size_t Arranging::bundleOf(size_t i) const {
  while (bundle[i] != i)
    i = bundle[i];
  return i;
}

TopoDS_Edge Arranging::edgeOf(const Piece &piece, double tolerance) {
  double a, b;
  TopoDS_Edge edge;
  builder.MakeEdge(edge, BRep_Tool::Curve(images[piece.tool].edge, a, b), tolerance);
  builder.Add(edge, meets[standing(piece.from)].vertex.Oriented(TopAbs_FORWARD));
  builder.Add(edge, meets[standing(piece.to)].vertex.Oriented(TopAbs_REVERSED));
  builder.Range(edge, piece.lo, piece.hi);
  return edge;
}

// How far the pieces of a bundle stand from its first piece, which stands
// for them all: the farthest of their ends and middles from it, with what
// tells each image apart. The arc they make stands for its images within
// this.
double Arranging::spreadOf(size_t lead, const std::vector<size_t> &members) const {
  const Piece &piece = pieces[lead];
  double spread = images[piece.tool].blur;
  for (const size_t member : members) {
    if (member == lead)
      continue;
    const Piece &other = pieces[member];
    for (const double t : {other.lo, (other.lo + other.hi) / 2, other.hi})
      spread = std::max(spread, nearest(at(other.tool, t), piece.tool, piece.lo, piece.hi).first + images[other.tool].blur);
  }
  return spread;
}

// A piece too short for OCCT to tell from its ends, within what the arc
// it would make stands for its images, is no piece: its ends
// are one point, whose vertex covers the piece and those it is one with.
bool Arranging::shorten() {
  bool any = false;
  for (const auto &[lead, members] : bundles) {
    const Piece &piece = pieces[lead];
    const size_t from = standing(piece.from), to = standing(piece.to);
    if (from == to)
      continue;
    // A piece is at least as long as its ends stand apart; one that is
    // too short lies within about its ends' tolerances.
    const double spread = spreadOf(lead, members);
    const double room = meets[from].reach + meets[to].reach + 2 * spread;
    if (meets[from].at.Distance(meets[to].at) > 2 * room + Precision::Confusion() ||
        !BOPTools_AlgoTools::IsMicroEdge(edgeOf(piece, spread), context))
      continue;
    const size_t kept = unite(from, to);
    for (const size_t member : members)
      for (const double t : {pieces[member].lo, (pieces[member].lo + pieces[member].hi) / 2, pieces[member].hi})
        grow(kept, meets[kept].at.Distance(at(pieces[member].tool, t)) + images[pieces[member].tool].blur +
                       Precision::Confusion());
    any = true;
  }
  return any;
}

// A vertex reaches as far as the pieces that are one curve of the plane
// and end there stand apart, where no closer can the plane tell their
// ends apart. False where every vertex did.
bool Arranging::cover() {
  bool grew = false;
  for (const auto &[lead, members] : bundles) {
    const double spread = spreadOf(lead, members);
    for (const size_t end : {pieces[lead].from, pieces[lead].to}) {
      const size_t vertex = standing(end);
      if (meets[vertex].reach < spread) {
        grow(vertex, spread);
        grew = true;
      }
    }
  }
  return grew;
}

// Beyond which end of a piece its image leaves the stretches it runs in
// along bounding images, where what covers it cannot be told: away from
// the points they run from. Between two points from which it runs along
// one image it leaves that image nowhere.
int Arranging::leaving(const Piece &piece) const {
  const double middle = (piece.lo + piece.hi) / 2;
  std::map<size_t, std::pair<bool, bool>> ways;
  for (const auto &s : stretches) {
    if (s.tool == piece.tool && images[s.other].bounds && s.first <= middle && middle <= s.last)
      (s.anchor <= middle ? ways[s.other].first : ways[s.other].second) = true;
    if (s.other == piece.tool && images[s.tool].bounds && s.from <= middle && middle <= s.to)
      (s.beside <= middle ? ways[s.tool].first : ways[s.tool].second) = true;
  }
  bool onward = false, back = false;
  for (const auto &[other, way] : ways) {
    onward = onward || (way.first && !way.second);
    back = back || (way.second && !way.first);
  }
  return onward == back ? 0 : onward ? 1 : -1;
}

// Each bundle's first piece stands for the others, and comes from each of
// them, within a tolerance that covers them.
std::vector<ArcPiece> Arranging::emit() {
  std::vector<ArcPiece> result;
  for (const auto &[lead, members] : bundles) {
    const auto &piece = pieces[lead];
    ArcPiece arc;
    const double tolerance = spreadOf(lead, members);
    for (const size_t member : members) {
      const auto &other = pieces[member];
      if (!(other.from == piece.from && other.to == piece.to) && !(other.from == piece.to && other.to == piece.from))
        throw std::runtime_error("images that run along each other are cut at different places");
      arc.parts.push_back({other.tool, other.lo, other.hi, leaving(other)});
    }
    arc.edge = edgeOf(piece, tolerance);
    // The arc's polyline is its image's, between its ends.
    const auto &image = images[piece.tool];
    arc.at.push_back(piece.lo);
    arc.points.push_back(at(piece.tool, piece.lo));
    for (auto it = std::upper_bound(image.at.begin(), image.at.end(), piece.lo + Precision::PConfusion());
         it != image.at.end() && *it < piece.hi - Precision::PConfusion(); ++it) {
      arc.at.push_back(*it);
      arc.points.push_back(image.points[static_cast<size_t>(it - image.at.begin())]);
    }
    arc.at.push_back(piece.hi);
    arc.points.push_back(at(piece.tool, piece.hi));
    // How far the image may stand from each segment, as the control
    // points of its pieces over the segment tell.
    for (size_t n = 0; n + 1 < arc.at.size(); ++n)
      arc.offs.push_back(hullOf(piece.tool, arc.at[n], arc.at[n + 1], arc.points[n], arc.points[n + 1]).off);
    arc.plane = image.plane;
    result.push_back(arc);
  }
  return result;
}
} // namespace huak::space
