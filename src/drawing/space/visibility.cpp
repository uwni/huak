#include "lighting.hxx"
#include <BOPTools_AlgoTools3D.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <IntTools_Context.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <algorithm>
#include <gp_Pln.hxx>
#include <map>
#include <stdexcept>
#include <tuple>

namespace huak::space {
Surfaces::Surfaces(const std::vector<TopoDS_Shape> &shapes)
    : probes(shapes.size()), faces(shapes.size()) {
  for (size_t i = 0; i < shapes.size(); ++i) {
    TopExp::MapShapes(shapes[i], TopAbs_FACE, faces[i]);
    if (faces[i].IsEmpty())
      continue;
    probes[i] = std::make_unique<IntCurvesFace_ShapeIntersector>();
    probes[i]->Load(shapes[i], Precision::Confusion());
    ++count;
  }
}

const std::vector<Hit> &Surfaces::along(const gp_Lin &ray,
                                        const gp_Dir &toward_eye) {
  hits.clear();
  for (size_t i = 0; i < probes.size(); ++i) {
    if (!probes[i])
      continue;
    auto &probe = *probes[i];
    probe.Perform(ray, -RealLast(), RealLast());
    if (!probe.IsDone())
      throw std::runtime_error("surface visibility query failed");
    for (int k = 1; k <= probe.NbPnt(); ++k)
      hits.push_back({probe.Pnt(k).XYZ().Dot(toward_eye.XYZ()),
                      i,
                      faces[i].FindIndex(probe.Face(k)) - 1,
                      {probe.UParameter(k), probe.VParameter(k)}});
  }
  std::sort(hits.begin(), hits.end(),
            [](const Hit &a, const Hit &b) { return a.depth > b.depth; });
  // A ray on the common edge of two faces of one solid can report both.
  // Separate shapes at the same depth remain distinct sheets, in input order.
  size_t write = 0;
  for (size_t first = 0; first < hits.size();) {
    size_t end = first + 1;
    while (end < hits.size() &&
           hits[first].depth - hits[end].depth <= Precision::Confusion())
      ++end;
    std::sort(hits.begin() + first, hits.begin() + end,
              [](const Hit &a, const Hit &b) {
                return std::tie(a.source, a.face) < std::tie(b.source, b.face);
              });
    for (size_t k = first; k < end; ++k)
      if (k == first || hits[k].source != hits[write - 1].source)
        hits[write++] = hits[k];
    first = end;
  }
  hits.resize(write);
  return hits;
}

void intersectShapes(const std::vector<TopoDS_Shape> &shapes,
                     const Surfaces &surfaces, std::vector<Feature> &features) {
  if (surfaces.count < 2)
    return;
  std::vector<Bnd_Box> boxes(shapes.size());
  for (size_t i = 0; i < shapes.size(); ++i) {
    if (!surfaces.probes[i])
      continue;
    BRepBndLib::Add(shapes[i], boxes[i], false);
    for (size_t j = 0; j < i; ++j) {
      if (!surfaces.probes[j] || boxes[i].IsOut(boxes[j]) ||
          shapes[i].IsSame(shapes[j]))
        continue;
      BRepAlgoAPI_Section section(shapes[j], shapes[i], false);
      section.Approximation(true);
      section.SetNonDestructive(true);
      section.Build();
      if (!section.IsDone())
        throw std::runtime_error("surface intersection failed");
      for (const auto &edge : section.SectionEdges())
        features.push_back({j, HUAK_INTERSECTION, std::nullopt,
                            TopoDS::Edge(edge), static_cast<ptrdiff_t>(i)});
    }
  }
}

void projectFaces(Result &out, Surfaces &surfaces,
                  const std::vector<TopoDS_Shape> &shapes,
                  const std::vector<TopoDS_Edge> &cell_boundaries,
                  const HLRAlgo_Projector &projector, const gp_Dir &toward_eye,
                  const HuakLight *light, double tolerance) {
  TopTools_ListOfShape tools;
  Bnd_Box bounds;
  auto boundary = [&](const TopoDS_Edge &edge) {
    if (!edge.IsNull()) {
      tools.Append(edge);
      BRepBndLib::Add(edge, bounds);
    }
  };
  for (const auto &edge : cell_boundaries)
    boundary(edge);
  for (const auto &shape : shapes) {
    TopTools_IndexedDataMapOfShapeListOfShape adjacent;
    TopExp::MapShapesAndUniqueAncestors(shape, TopAbs_EDGE, TopAbs_FACE,
                                        adjacent);
    for (int i = 1; i <= adjacent.Extent(); ++i) {
      const auto &faces = adjacent.FindFromIndex(i);
      const auto &edge = TopoDS::Edge(adjacent.FindKey(i));
      // A periodic seam joins two parameter limits of the same face.
      // Genuine boundaries, including smooth joins between faces, divide cells.
      if (faces.IsEmpty() ||
          (faces.Extent() == 1 &&
           BRep_Tool::IsClosed(edge, TopoDS::Face(faces.First()))))
        continue;
      boundary(projected(edge, projector, tolerance));
    }
  }
  std::optional<Lighting> lighting;
  if (light)
    lighting.emplace(*light, surfaces, projector, toward_eye, tolerance, tools);
  if (bounds.IsVoid() || tools.IsEmpty())
    return;

  double x0, y0, z0, x1, y1, z1;
  bounds.Get(x0, y0, z0, x1, y1, z1);
  const double margin = std::max({x1 - x0, y1 - y0, 1.0});
  TopTools_ListOfShape objects;
  objects.Append(BRepBuilderAPI_MakeFace(gp_Pln(gp::XOY()), x0 - margin,
                                         x1 + margin, y0 - margin, y1 + margin)
                     .Face());
  BRepAlgoAPI_Splitter split;
  split.SetArguments(objects);
  split.SetTools(tools);
  split.Build();
  if (!split.IsDone())
    throw std::runtime_error("projected face subdivision failed");
  BRep_Builder builder;
  Handle(IntTools_Context) context = new IntTools_Context();
  // Merge neighboring cells only where the same sheet has the same rank.
  struct Regions {
    TopoDS_Compound body, spot;
    std::map<double, TopoDS_Compound> shades;
  };
  std::map<std::tuple<size_t, size_t, int>, Regions> groups;
  auto add = [&](TopoDS_Compound &group, const TopoDS_Face &cell) {
    if (group.IsNull())
      builder.MakeCompound(group);
    builder.Add(group, cell);
  };
  for (TopExp_Explorer cells(split.Shape(), TopAbs_FACE); cells.More();
       cells.Next()) {
    auto cell = TopoDS::Face(cells.Current());
    gp_Pnt sample;
    gp_Pnt2d uv;
    if (BOPTools_AlgoTools3D::PointInFace(cell, sample, uv, context))
      throw std::runtime_error("cannot locate projected face interior");
    const gp_Lin ray = projector.Shoot(sample.X(), sample.Y());
    const auto &hits = surfaces.along(ray, toward_eye);
    for (size_t covering = 0; covering < hits.size(); ++covering) {
      const auto &hit = hits[covering];
      auto &group = groups[{covering, hit.source, hit.face}];
      add(group.body, cell);
      if (lighting) {
        const auto sample = lighting->classify(
            hit, TopoDS::Face(surfaces.faces[hit.source](hit.face + 1)), cell);
        add(group.shades[sample.diffuse], cell);
        if (sample.gleam)
          add(group.spot, cell);
      }
    }
  }
  if (lighting)
    lighting->fitSpots(out);
  auto write = [&](const TopoDS_Compound &cells) {
    if (cells.IsNull())
      return;
    ShapeUpgrade_UnifySameDomain merge(cells, true, true);
    merge.Build();
    for (TopExp_Explorer it(merge.Shape(), TopAbs_FACE); it.More(); it.Next()) {
      auto cell = TopoDS::Face(it.Current());
      cell.Orientation(TopAbs_FORWARD);
      for (TopExp_Explorer w(cell, TopAbs_WIRE); w.More(); w.Next()) {
        const auto start = out.commands.size();
        for (BRepTools_WireExplorer e(TopoDS::Wire(w.Current()), cell);
             e.More(); e.Next())
          writeEdge(out, e.Current(), tolerance, out.commands.size() == start);
        if (out.commands.size() > start) {
          // Both ends of a wire share one vertex. Independent evaluations of
          // the same point must not create an extra microscopic closing edge.
          auto &last = out.commands.back();
          last.p[last.op == HUAK_BEZIER ? 2 : 0] = out.commands[start].p[0];
          out.commands.push_back({HUAK_CLOSE, {}});
        }
      }
    }
  };
  const FaceLight unlit{};
  for (const auto &[owner, regions] : groups) {
    const auto &[covering, source, face] = owner;
    const auto start = out.commands.size();
    write(regions.body);
    const auto end = out.commands.size();
    const auto &paint = lighting ? lighting->face(source, face) : unlit;
    // A plane has one normal, so a gleam covers its entire visible region.
    const bool full_spot = paint.planar && !regions.spot.IsNull();
    if (!full_spot)
      write(regions.spot);
    const auto spot_start = full_spot ? start : end;
    const auto spot_count = out.commands.size() - spot_start;
    const auto shade_start = out.shades.size();
    for (const auto &[diffuse, cells] : regions.shades) {
      if (regions.shades.size() == 1) {
        out.shades.push_back({start, end - start, diffuse});
        continue;
      }
      const auto first = out.commands.size();
      write(cells);
      out.shades.push_back({first, out.commands.size() - first, diffuse});
    }
    out.faces.push_back({source, static_cast<size_t>(face), start, end - start,
                         covering, spot_start, spot_count,
                         paint.start, paint.count, shade_start,
                         out.shades.size() - shade_start});
  }
}
} // namespace huak::space
