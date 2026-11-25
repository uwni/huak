// Arranging the images: where their curves meet, the edges and layers they
// bound, and the view's arcs.
#include "view.hxx"

namespace {
// The points of the image where the curves of the tools on faces end in
// space, each with how far from it the curves that end there may pass: the
// tolerance of the vertex there, on an edge of the face or where the curve
// goes on as another, which the images alone do not tell. Points whose
// images coincide are one point of the image. Where else images meet, the
// arrangement finds in the plane: a curve that crosses a curve along which
// its face folds over shows touching it there.
std::vector<Meeting> meetingsOf(HuakView *view, const size_t *tools, size_t count) {
  std::vector<Meeting> meetings;
  // A point in space where curves meet, with its tolerance, shown where the
  // curve it was found on is stretched so much.
  const auto meetAt = [&](const gp_Pnt &p, double tolerance, double stretched) {
    const HuakLook seen = view->look(p);
    const gp_Pnt2d shown(seen.x, seen.y);
    const auto found = std::find_if(meetings.begin(), meetings.end(), [&](const Meeting &m) {
      return m.at.Distance(shown) <= m.within + tolerance * stretched + Precision::Confusion();
    });
    if (found == meetings.end())
      meetings.push_back({shown, tolerance * stretched});
    else
      found->within = std::max(found->within, tolerance * stretched + found->at.Distance(shown));
  };
  for (size_t k = 0; k < count; ++k) {
    const size_t curve = element(view->sources, tools[k], "image").curve;
    const auto &edge = view->curve(curve);
    const auto on = view->facesOf.find(curve);
    if (on == view->facesOf.end())
      continue;
    const double stretched = magnification(edge, view->projector);
    for (TopExp_Explorer v(edge, TopAbs_VERTEX); v.More(); v.Next())
      meetAt(BRep_Tool::Pnt(TopoDS::Vertex(v.Current())), BRep_Tool::Tolerance(TopoDS::Vertex(v.Current())), stretched);
  }
  return meetings;
}

// The edges of a face.
const ShapeSet &edgesOf(HuakView *view, size_t source, size_t index) {
  const auto key = std::make_pair(source, index);
  if (const auto found = view->faceEdges.find(key); found != view->faceEdges.end())
    return found->second;
  ShapeSet edges;
  for (TopExp_Explorer e(faceOf(&view->model, source, index), TopAbs_EDGE); e.More(); e.Next())
    edges.Add(e.Current());
  return view->faceEdges.emplace(key, std::move(edges)).first->second;
}

// Whether a curve bounds layers of a face, so that what lies beside its image
// differs from one side to the other: where the face folds over along it,
// or where it is an edge of the face other than a seam, across which the
// face's layer runs on. A curve that only lies on a face, where two shapes
// meet, bounds none of its layers.
bool boundsLayers(HuakView *view, size_t curve) {
  const auto on = view->facesOf.find(curve);
  if (on == view->facesOf.end())
    return false;
  const auto &shown = view->curve(curve);
  return std::any_of(on->second.begin(), on->second.end(), [&](const HuakView::OnFace &face) {
    return face.folds || (edgesOf(view, face.source, face.face).Contains(shown) &&
                          !BRep_Tool::IsClosed(shown, faceOf(&view->model, face.source, face.face)));
  });
}

// Where an image that runs along an arc passes the arc's point at `at`: at
// the same parameter where the arc keeps the image's curve, otherwise where
// the part of the image along the arc stands nearest the point.
double onImage(HuakView *view, const HuakView::Arc &arc, const HuakView::Arc::Along &along, double at) {
  if (along.keeps)
    return at;
  const gp_Pnt2d p = arc.curve->Value(at);
  const auto &plane = view->plane(along.image);
  double best = plane->Value(along.first).Distance(p) <= plane->Value(along.last).Distance(p) ? along.first : along.last;
  Geom2dAPI_ProjectPointOnCurve onto(p, plane, along.first, along.last);
  if (onto.NbPoints() && onto.LowerDistance() < plane->Value(best).Distance(p))
    best = onto.LowerDistanceParameter();
  return best;
}
} // namespace

namespace huak::space::entry {
double leaving(const HuakView::Arc &arc, bool fromTail, const gp_Pnt2d &centre, double reach) {
  struct Away : math_Function {
    const Adaptor2d_Curve2d &curve;
    gp_Pnt2d centre;
    double reach;
    Away(const Adaptor2d_Curve2d &curve, const gp_Pnt2d &centre, double reach)
        : curve(curve), centre(centre), reach(reach) {}
    bool Value(double t, double &f) override {
      f = curve.Value(t).Distance(centre) - reach;
      return true;
    }
  };
  const size_t n = arc.points.size();
  const auto from = [&](size_t i) { return fromTail ? i : n - 1 - i; };
  size_t farthest = from(0);
  for (size_t i = 0; i < n; ++i) {
    const gp_Pnt2d &p = arc.points[from(i)];
    if (p.Distance(centre) < reach) {
      if (p.Distance(centre) > arc.points[farthest].Distance(centre))
        farthest = from(i);
      continue;
    }
    if (i == 0)
      return arc.at[from(i)];
    Away away(*arc.curve, centre, reach);
    const double a = arc.at[from(i - 1)], b = arc.at[from(i)];
    math_BracketedRoot root(away, std::min(a, b), std::max(a, b), Precision::PConfusion());
    if (!root.IsDone())
      throw std::runtime_error("cannot find where an arc leaves a vertex");
    return root.Root();
  }
  return arc.at[farthest];
}

int arrange(HuakView *view, const size_t *images, size_t count, const HuakCut *cuts,
            size_t cut_count, HuakArcs *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(images, count, "images");
    requireArray(cuts, cut_count, "cuts");
    require(out, "out");
    std::map<size_t, size_t> toolOf;
    std::vector<TopoDS_Edge> edges;
    for (size_t k = 0; k < count; ++k) {
      edges.push_back(view->image(images[k]));
      if (!toolOf.emplace(images[k], k).second)
        throw InvalidArgument("an image is arranged twice");
    }
    std::vector<Passage> apart;
    for (size_t k = 0; k < cut_count; ++k) {
      const auto found = toolOf.find(cuts[k].image);
      if (found == toolOf.end())
        throw InvalidArgument("a cut names an image that is not arranged");
      apart.push_back({found->second, cuts[k].parameter});
    }
    // What lies beside an image differs from one side to the other where
    // its curve bounds layers.
    std::vector<bool> bounds;
    for (size_t k = 0; k < count; ++k)
      bounds.push_back(boundsLayers(view, view->sources[images[k]].curve));
    const auto pieces =
        arrangeImages(edges, bounds, meetingsOf(view, images, count), apart);
    view->arcs.clear();
    auto &items = view->result(view->arcItems);
    auto &rows = view->result(view->arcOrigins);
    for (const auto &piece : pieces) {
      HuakView::Arc arc;
      arc.edge = piece.edge;
      BRep_Tool::Range(arc.edge, arc.first, arc.last);
      arc.curve = new Geom2dAdaptor_Curve(piece.plane);
      arc.at = piece.at;
      arc.points = piece.points;
      arc.offs = piece.offs;
      arc.blur = BRep_Tool::Tolerance(arc.edge);
      TopoDS_Vertex tail, head;
      TopExp::Vertices(arc.edge, tail, head);
      {
        const gp_Pnt from = BRep_Tool::Pnt(tail), to = BRep_Tool::Pnt(head);
        arc.tail = gp_Pnt2d(from.X(), from.Y());
        arc.head = gp_Pnt2d(to.X(), to.Y());
        arc.tailReach = BRep_Tool::Tolerance(tail);
        arc.headReach = BRep_Tool::Tolerance(head);
        arc.tailLeaves = leaving(arc, true, arc.tail, arc.tailReach);
        arc.headLeaves = leaving(arc, false, arc.head, arc.headReach);
      }
      {
        double from = arc.first, to = arc.last;
        BRepLib::FindValidRange(arc.edge, from, to);
        arc.middle = (from + to) / 2;
      }
      // The box about its polyline, as far as it may stand from it.
      for (const auto &p : arc.points)
        arc.box.Add(p.XY());
      arc.box.Enlarge(*std::max_element(arc.offs.begin(), arc.offs.end()) + arc.blur + Precision::Confusion());
      // The arc keeps the curve of the image it is a piece of, over that
      // piece: another piece of that image may run back along it.
      for (const auto &part : piece.parts) {
        double f, l;
        const bool keeps = BRep_Tool::Curve(arc.edge, f, l) == BRep_Tool::Curve(edges[part.tool], f, l) &&
                           std::abs(part.first - arc.first) <= Precision::PConfusion() &&
                           std::abs(part.last - arc.last) <= Precision::PConfusion();
        arc.along.push_back({images[part.tool], part.first, part.last, keeps, part.leaves, 0});
        arc.along.back().middle = onImage(view, arc, arc.along.back(), arc.middle);
      }
      const gp_Pnt2d at = arc.curve->Value(arc.middle);
      const size_t first = rows.size();
      for (const auto &along : arc.along) {
        const double over = along.middle;
        HuakArcOrigin origin{along.image, along.first, along.last, along.leaves, view->depth(view->spacePoint(along.image, over)),
                             view->curveTolerance(along.image), {HUAK_NO_FACE, HUAK_NO_FACE}, {HUAK_NO_FACE, HUAK_NO_FACE}};
        const auto on = view->facesOf.find(element(view->sources, along.image, "image").curve);
        if (on != view->facesOf.end()) {
          if (on->second.size() > 2)
            throw std::runtime_error("a curve lies on more than two faces");
          for (size_t i = 0; i < on->second.size(); ++i) {
            origin.source[i] = on->second[i].source;
            origin.face[i] = on->second[i].face;
          }
        }
        rows.push_back(origin);
      }
      items.push_back({at.X(), at.Y(), first, rows.size() - first});
      view->arcs.push_back(std::move(arc));
    }
    *out = {items.data(), rows.data(), items.size()};
  });
}
} // namespace huak::space::entry
