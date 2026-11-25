// The arrangement's construction, its vertices and the settling loop, and its
// one entry, `arrangeImages`.
#include "arranging.hxx"

namespace huak::space {
Arranging::Arranging(const std::vector<TopoDS_Edge> &edges, const std::vector<bool> &bounding)
    : context(new IntTools_Context()) {
  images.resize(edges.size());
  stretchesOf.resize(edges.size());
  for (size_t k = 0; k < edges.size(); ++k) {
    auto &image = images[k];
    image.edge = edges[k];
    image.plane = inPlane(edges[k]);
    BRep_Tool::Range(edges[k], image.first, image.last);
    image.blur = BRep_Tool::Tolerance(edges[k]);
    image.bounds = bounding[k];
    image.adaptor = new Geom2dAdaptor_Curve(image.plane, image.first, image.last);
    cutIntoPieces(image);
    outline(k);
  }
  // An image ends at its own vertices, and is cut where it turns back.
  for (size_t k = 0; k < edges.size(); ++k) {
    TopoDS_Vertex head, tail;
    TopExp::Vertices(edges[k], head, tail);
    pass(k, images[k].first, meetOf(head));
    pass(k, images[k].last, meetOf(tail));
    for (const double turn : images[k].turns)
      cut({k, turn});
  }
}

// Images meet at a point of the plane: one vertex there, through which
// each passes that passes within `within` of the point.
void Arranging::meet(const gp_Pnt2d &at, double within) { vertexAt(at, within + Precision::Confusion()); }

// An image is cut at a parameter.
void Arranging::cut(const Passage &where) {
  pass(where.image, where.at, vertexAt(at(where.image, where.at), images[where.image].blur));
}

std::vector<ArcPiece> Arranging::arcs() {
  // The images that pass where curves meet in space pass through there;
  // then those that cross in the plane meet.
  through();
  cross();
  close();
  return emit();
}

size_t Arranging::meetOf(const TopoDS_Vertex &vertex) {
  const auto found = known.find(vertex.TShape().get());
  if (found != known.end())
    return standing(found->second);
  const gp_Pnt p = BRep_Tool::Pnt(vertex);
  meets.push_back({vertex, gp_Pnt2d(p.X(), p.Y()), BRep_Tool::Tolerance(vertex), {}, -1, -1, meets.size()});
  known.emplace(vertex.TShape().get(), meets.size() - 1);
  return meets.size() - 1;
}

size_t Arranging::vertexAt(const gp_Pnt2d &at, double reach) {
  TopoDS_Vertex vertex;
  builder.MakeVertex(vertex, gp_Pnt(at.X(), at.Y(), 0), reach);
  return meetOf(vertex);
}

// A vertex reaches at least so far.
void Arranging::grow(size_t vertex, double reach) {
  auto &meet = meets[vertex];
  if (reach <= meet.reach)
    return;
  builder.UpdateVertex(meet.vertex, reach);
  meet.reach = BRep_Tool::Tolerance(meet.vertex);
}

// An image's cut at a parameter, if it is cut there: at the parameter, or
// where it stays within its tolerance of the cut's point from there. Of
// its cuts, in order along it, that is the one before or the one after.
const Arranging::Cut *Arranging::cutNear(size_t k, double t) const {
  const auto &cuts = images[k].cuts;
  const auto next = std::lower_bound(cuts.begin(), cuts.end(), t, [](const Cut &cut, double at) { return cut.at < at; });
  const gp_Pnt2d p = at(k, t);
  const double reach = images[k].blur + Precision::Confusion();
  for (const auto &cut : {next, next == cuts.begin() ? cuts.end() : next - 1}) {
    if (cut == cuts.end())
      continue;
    if (std::abs(cut->at - t) <= Precision::PConfusion())
      return &*cut;
    if (cut->point.Distance(p) <= reach && staysWithin(k, cut->at, t, p, reach))
      return &*cut;
  }
  return nullptr;
}

// Two vertices are one point: the one that reaches farther covers the
// other and stands for it, and the images through either pass through it.
size_t Arranging::unite(size_t one, size_t other) {
  one = standing(one);
  other = standing(other);
  if (one == other)
    return one;
  const size_t kept = meets[one].reach >= meets[other].reach ? one : other, gone = kept == one ? other : one;
  grow(kept, meets[kept].at.Distance(meets[gone].at) + meets[gone].reach);
  meets[gone].same = kept;
  const auto joining = std::move(meets[gone].through);
  const auto there = meets[kept].through;
  meets[kept].through.insert(meets[kept].through.end(), joining.begin(), joining.end());
  for (const auto &passage : joining)
    for (const auto &through : there)
      relate(kept, passage, through);
  return kept;
}

// An image passes through a vertex at a parameter: it is cut there, at a
// vertex that covers its point there. Where it is cut there already, the
// two vertices are one. False where it passed through it there.
bool Arranging::pass(size_t k, double t, size_t vertex) {
  vertex = standing(vertex);
  const gp_Pnt2d p = at(k, t);
  grow(vertex, meets[vertex].at.Distance(p) + images[k].blur + Precision::Confusion());
  if (const Cut *cut = cutNear(k, t)) {
    if (standing(cut->vertex) == vertex)
      return false;
    unite(cut->vertex, vertex);
    return true;
  }
  auto &cuts = images[k].cuts;
  cuts.insert(std::lower_bound(cuts.begin(), cuts.end(), t, [](const Cut &cut, double at) { return cut.at < at; }),
              {t, p, vertex});
  const auto there = meets[vertex].through;
  meets[vertex].through.push_back({k, t});
  for (const auto &through : there)
    relate(vertex, {k, t}, through);
  if (turnsAt(k, t))
    relate(vertex, {k, t}, {k, t});
  return true;
}

// An image that passes within a vertex passes through it.
bool Arranging::through() {
  bool cut = false;
  for (size_t v = 0; v < meets.size(); ++v) {
    if (meets[v].same != v || meets[v].passed >= meets[v].reach)
      continue;
    // The vertex may grow as images pass through it: as far as it reached
    // when the images were sought.
    const double sought = meets[v].reach;
    for (size_t k = 0; k < images.size(); ++k) {
      const auto &image = images[k];
      const size_t vertex = standing(v);
      const gp_Pnt2d centre = meets[vertex].at;
      const double reach = meets[vertex].reach + image.blur;
      if (image.box.IsOut(centre.XY(), reach))
        continue;
      // Each part of the image's polyline that comes within reach, once.
      for (size_t n = 0; n + 1 < image.at.size(); ++n) {
        if (apart(centre, image.points[n], image.points[n + 1]) > reach + image.offs[n])
          continue;
        size_t end = n;
        while (end + 2 < image.at.size() && apart(centre, image.points[end + 1], image.points[end + 2]) <= reach + image.offs[end + 1])
          ++end;
        const auto found = nearestOver(centre, k, n, end);
        const double off = found.first, t = found.second;
        n = end;
        if (off > reach)
          continue;
        if (std::any_of(image.cuts.begin(), image.cuts.end(), [&](const Cut &c) {
              return standing(c.vertex) == vertex && (std::abs(c.at - t) <= Precision::PConfusion() || within(k, c.at, t, vertex));
            }))
          continue;
        if (pass(k, t, vertex))
          cut = true;
      }
    }
    meets[v].passed = sought;
  }
  return cut;
}

// Vertices that reach each other are one point.
bool Arranging::coincide() {
  bool any = false;
  for (size_t v = 0; v < meets.size(); ++v) {
    if (meets[v].same != v || meets[v].compared >= meets[v].reach)
      continue;
    const double compared = meets[v].reach;
    for (size_t w = 0; w < meets.size(); ++w) {
      const size_t one = standing(v);
      if (meets[w].same != w || w == one || meets[one].at.Distance(meets[w].at) > meets[one].reach + meets[w].reach)
        continue;
      unite(one, w);
      any = true;
    }
    meets[v].compared = compared;
  }
  return any;
}

// The images are cut until nothing more follows: alike along stretches,
// where they pass through vertices, with vertices that reach each other
// one point, vertices reaching as far as the pieces ending there stand
// apart, and without pieces too short to tell from their ends.
void Arranging::close() {
  for (int round = 0;; ++round) {
    if (round == 4096)
      throw std::runtime_error("the images' cuts do not settle");
    const bool cut = alike(), passed = through(), united = coincide();
    if (cut || passed || united || !divide() || cover())
      continue;
    if (!shorten())
      return;
  }
}

std::vector<ArcPiece> arrangeImages(const std::vector<TopoDS_Edge> &images,
                                    const std::vector<bool> &bounding, const std::vector<Meeting> &meetings,
                                    const std::vector<Passage> &cuts) {
  Arranging arranging(images, bounding);
  for (const auto &meeting : meetings)
    arranging.meet(meeting.at, meeting.within);
  for (const auto &cut : cuts)
    arranging.cut(cut);
  return arranging.arcs();
}
} // namespace huak::space
