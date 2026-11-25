// The space curves of the shapes, and their images and pieces: edges, rims,
// sections, projections, piercings, approximations and contours.
#include "view.hxx"

namespace huak::space::entry {
int curves(HuakView *view, size_t source, HuakIndices *out, char *error,
           size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    auto &items = view->result(view->indices);
    for (TopExp_Explorer e(shapeOf(&view->model, source), TopAbs_EDGE); e.More(); e.Next()) {
      const auto &edge = TopoDS::Edge(e.Current());
      const size_t curve = view->addCurve(edge);
      items.push_back(curve);
      // A curve drawn on the surface of a face of one of the shapes lies
      // on that face, as far as the face goes.
      Handle(Geom2d_Curve) drawn;
      Handle(Geom_Surface) surface;
      TopLoc_Location place;
      double first, last;
      BRep_Tool::CurveOnSurface(edge, drawn, surface, place, first, last);
      if (surface.IsNull())
        continue;
      for (size_t shape = 0; shape < view->model.faces.size(); ++shape)
        for (int i = 1; i <= view->model.faces[shape].Extent(); ++i) {
          TopLoc_Location there;
          if (BRep_Tool::Surface(TopoDS::Face(view->model.faces[shape](i)), there) == surface && there == place)
            view->facesOf[curve].push_back({shape, static_cast<size_t>(i - 1), false, true});
        }
    }
    *out = {items.data(), items.size()};
  });
}

int edges(HuakView *view, size_t source, HuakEdges *out, char *error,
          size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    const auto &shape = shapeOf(&view->model, source);
    NCollection_IndexedDataMap<TopoDS_Shape, ShapeList, TopTools_ShapeMapHasher>
        adjacent, uses;
    TopExp::MapShapesAndUniqueAncestors(shape, TopAbs_EDGE, TopAbs_FACE, adjacent);
    // Each use of an edge by a face, as hidden-line removal counts them: a
    // seam twice by its one face.
    for (TopExp_Explorer f(shape, TopAbs_FACE); f.More(); f.Next())
      TopExp::MapShapesAndAncestors(f.Current(), TopAbs_EDGE, TopAbs_FACE, uses);
    auto &items = view->result(view->edges);
    const auto &index = element(view->model.faces, source, "shape");
    for (int i = 1; i <= adjacent.Extent(); ++i) {
      const auto &faces = adjacent.FindFromIndex(i);
      const auto &edge = TopoDS::Edge(adjacent.FindKey(i));
      const bool closed =
          faces.Extent() == 1 &&
          BRep_Tool::IsClosed(edge, TopoDS::Face(faces.First()));
      // Between two uses, its kind follows OCCT's continuity across it.
      int kind = HUAK_EDGE;
      const ShapeList *used = uses.Seek(edge);
      if (used && used->Extent() == 2) {
        const GeomAbs_Shape continuity = BRep_Tool::Continuity(
            edge, TopoDS::Face(used->First()), TopoDS::Face(used->Last()));
        kind = continuity >= GeomAbs_G2 ? HUAK_SEAM : continuity >= GeomAbs_G1 ? HUAK_SMOOTH : HUAK_EDGE;
      }
      HuakEdge record{view->edgeCurve(source, edge), static_cast<size_t>(faces.Extent()),
                      {HUAK_NO_FACE, HUAK_NO_FACE}, closed, kind};
      size_t k = 0;
      for (const auto &face : faces) {
        if (k == 2)
          break;
        const int found = index.FindIndex(face);
        record.face[k++] = found > 0 ? static_cast<size_t>(found - 1) : HUAK_NO_FACE;
      }
      auto &on = view->facesOf[record.curve];
      for (const size_t face : record.face)
        if (face != HUAK_NO_FACE &&
            std::none_of(on.begin(), on.end(), [&](const auto &at) { return at.source == source && at.face == face; }))
          on.push_back({source, face, false});
      items.push_back(record);
    }
    *out = {items.data(), items.size()};
  });
}

int rims(HuakView *view, size_t source, HuakRims *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    const auto &faces = element(view->model.faces, source, "shape");
    auto &items = view->result(view->rims);
    for (int i = 1; i <= faces.Extent(); ++i) {
      const size_t index = static_cast<size_t>(i - 1);
      const auto traced = traceOutlines(TopoDS::Face(faces(i)), view->projector);
      // The face folds over along its outline.
      for (const auto &edge : traced.curves) {
        const size_t curve = view->addCurve(edge);
        view->facesOf[curve].push_back({source, index, true});
        items.push_back({curve, index});
      }
      // An edge of the face that the outline runs along is a piece of it.
      for (const auto &edge : traced.along) {
        const size_t curve = view->edgeCurve(source, edge);
        auto &on = view->facesOf[curve];
        const auto at = std::find_if(on.begin(), on.end(), [&](const auto &f) { return f.source == source && f.face == index; });
        if (at == on.end())
          on.push_back({source, index, true});
        else
          at->folds = true;
        items.push_back({curve, index});
      }
    }
    *out = {items.data(), items.size()};
  });
}

int sections(HuakView *view, size_t first, size_t second, HuakSections *out,
             char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(out, "out");
    const auto &one = shapeOf(&view->model, first), &two = shapeOf(&view->model, second);
    BRepAlgoAPI_Section section(one, two, false);
    section.Approximation(true);
    // Each curve with its curve on the face of each shape it lies on.
    section.ComputePCurveOn1(true);
    section.ComputePCurveOn2(true);
    section.SetNonDestructive(true);
    section.Build();
    if (!section.IsDone())
      throw std::runtime_error("surface intersection failed");
    const auto faceOn = [&](size_t source, const TopoDS_Face &face) {
      const int found = element(view->model.faces, source, "shape").FindIndex(face);
      return found > 0 ? static_cast<size_t>(found - 1) : HUAK_NO_FACE;
    };
    auto &items = view->result(view->sections);
    for (const auto &edge : section.SectionEdges()) {
      TopoDS_Shape onFirst, onSecond;
      HuakSection record{view->addCurve(TopoDS::Edge(edge)), {HUAK_NO_FACE, HUAK_NO_FACE}};
      if (section.HasAncestorFaceOn1(edge, onFirst))
        record.face[0] = faceOn(first, TopoDS::Face(onFirst));
      if (section.HasAncestorFaceOn2(edge, onSecond))
        record.face[1] = faceOn(second, TopoDS::Face(onSecond));
      for (const auto &[source, face] : {std::pair{first, record.face[0]}, std::pair{second, record.face[1]}})
        if (face != HUAK_NO_FACE)
          view->facesOf[record.curve].push_back({source, face, false});
      items.push_back(record);
    }
    *out = {items.data(), items.size()};
  });
}

int project(HuakView *view, const size_t *curves, size_t count, int spline,
            double tolerance, ptrdiff_t *images, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(curves, count, "curves");
    requireArray(images, count, "images");
    for (size_t k = 0; k < count; ++k) {
      const auto &edge = view->curve(curves[k]);
      const auto image =
          spline ? projected(BRepBuilderAPI_MakeEdge(view->spline(curves[k])),
                             view->projector, tolerance)
                 : projected(edge, view->projector, tolerance);
      if (image.IsNull()) {
        images[k] = -1;
        continue;
      }
      // The image lies within its curve's tolerance, stretched as the
      // projection stretches distances there, of the true image.
      const double within = BRep_Tool::Tolerance(edge) * magnification(edge, view->projector);
      if (within > BRep_Tool::Tolerance(image)) {
        BRep_Builder builder;
        builder.UpdateEdge(image, within);
        for (TopExp_Explorer v(image, TopAbs_VERTEX); v.More(); v.Next())
          if (BRep_Tool::Tolerance(TopoDS::Vertex(v.Current())) < within)
            builder.UpdateVertex(TopoDS::Vertex(v.Current()), within);
      }
      double a, b;
      const auto curve = BRep_Tool::Curve(edge, a, b);
      const bool line = !spline && curve->IsKind(STANDARD_TYPE(Geom_Line));
      images[k] = static_cast<ptrdiff_t>(view->addImage(image, {curves[k], line}));
    }
  });
}

int pierce(HuakView *view, const HuakPair *pairs, size_t count, HuakRows *out,
           char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(pairs, count, "pairs");
    require(out, "out");
    auto &offsets = view->result(view->indices);
    auto &values = view->result(view->numbers);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      const auto &spline = view->spline(pairs[k].first);
      const size_t shape = pairs[k].second;
      shapeOf(&view->model, shape);
      if (!view->model.probes[shape])
        throw std::invalid_argument("shape has no faces");
      const Handle(GeomAdaptor_Curve) curve = new GeomAdaptor_Curve(spline);
      // Where the curve touches a face, or runs along it, it does not pass
      // through.
      const auto passes = [&](auto &probe) {
        probe.Perform(curve, spline->FirstParameter(), spline->LastParameter());
        if (!probe.IsDone())
          throw std::runtime_error("space curve intersection failed");
        for (int i = 1; i <= probe.NbPnt(); ++i)
          if (probe.Transition(i) != IntCurveSurface_Tangent)
            values.push_back(probe.WParameter(i));
      };
      // Nor does it pass through a face it lies on: where it lies on faces
      // of the shape, only the others are asked.
      const auto &faces = view->model.faces[shape];
      const auto on = view->facesOf.find(pairs[k].first);
      const auto lies = [&](int face) {
        return on != view->facesOf.end() && std::any_of(on->second.begin(), on->second.end(), [&](const HuakView::OnFace &lying) {
                 return lying.source == shape && static_cast<int>(lying.face) + 1 == face;
               });
      };
      bool lying = false;
      for (int face = 1; face <= faces.Extent() && !lying; ++face)
        lying = lies(face);
      if (!lying) {
        passes(*view->model.probes[shape]);
      } else {
        for (int face = 1; face <= faces.Extent(); ++face) {
          if (lies(face))
            continue;
          IntCurvesFace_Intersector probe(TopoDS::Face(faces(face)), Precision::Confusion());
          passes(probe);
        }
      }
      offsets.push_back(values.size());
    }
    *out = {offsets.data(), values.data(), count};
  });
}

int approximate(HuakView *view, const HuakPiece *pieces, size_t count,
                double tolerance, HuakPaths *out, char *error,
                size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    requireArray(pieces, count, "pieces");
    require(out, "out");
    auto &offsets = view->result(view->indices);
    auto &commands = view->result(view->paths);
    offsets.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      const auto &image = view->image(pieces[k].image);
      if (pieces[k].whole) {
        writeEdge(commands, image, tolerance);
      } else {
        double first, last;
        const auto curve = BRep_Tool::Curve(image, first, last);
        writeEdge(commands,
                  BRepBuilderAPI_MakeEdge(curve, pieces[k].first, pieces[k].last),
                  tolerance);
      }
      offsets.push_back(commands.size());
    }
    *out = {offsets.data(), commands.data(), count};
  });
}

int contours(HuakView *view, size_t source, size_t face,
             const double direction[3], double angle, HuakIndices *out,
             char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(direction, "direction");
    require(out, "out");
    auto &items = view->result(view->indices);
    // The contours lie on the face without bounding its layers.
    for (const auto &edge : traceContours(faceOf(&view->model, source, face),
                                          gp_Dir(direction[0], direction[1], direction[2]), angle)) {
      const size_t curve = view->addCurve(edge);
      view->facesOf[curve].push_back({source, face, false});
      items.push_back(curve);
    }
    *out = {items.data(), items.size()};
  });
}
} // namespace huak::space::entry
