// Planar partition of projected faces by image edges.
#include "space.hxx"
#include <BOPAlgo_PaveFiller.hxx>
#include <BOPDS_DS.hxx>
#include <BOPDS_Interf.hxx>
#include <BOPDS_PaveBlock.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRep_Tool.hxx>
#include <IntTools_Tools.hxx>
#include <TopoDS.hxx>
#include <stdexcept>

namespace huak::space {
namespace {
class Intersections : public BOPAlgo_PaveFiller {
  void PerformEE(const Message_ProgressRange &range) override {
    BOPAlgo_PaveFiller::PerformEE(range);
    if (HasErrors())
      return;
    // OCCT reprojects new intersection vertices to recover edge parameters.
    // Near a turning point that projection can find a different local minimum.
    // Retain the already computed E/E parameters on both incident edges instead
    // of leaving an intersection vertex connected to only one of them.
    NCollection_Map<int> changed;
    for (const auto &hit : myDS->InterfEE()) {
      const auto &part = hit.CommonPart();
      if (hit.IndexNew() < 0 || part.Type() != TopAbs_VERTEX)
        continue;
      int vertex = hit.IndexNew(), merged;
      if (myDS->HasShapeSD(vertex, merged))
        vertex = merged;
      const auto &v = TopoDS::Vertex(myDS->Shape(vertex));
      double parameters[2];
      IntTools_Tools::VertexParameters(part, parameters[0], parameters[1]);
      for (int side = 0; side < 2; ++side) {
        const auto &edge = side ? part.Edge2() : part.Edge1();
        const double t = parameters[side];
        double first, last;
        const auto curve = BRep_Tool::Curve(edge, first, last);
        // Merged vertices must still satisfy the original modeling tolerance.
        if (BRep_Tool::Pnt(v).Distance(curve->Value(t)) >
            BRep_Tool::Tolerance(v) + BRep_Tool::Tolerance(edge) + FuzzyValue())
          continue;
        const int index = myDS->Index(edge);
        for (const auto &block : myDS->PaveBlocks(index)) {
          double lo, hi;
          block->Range(lo, hi);
          if (t <= lo + Precision::PConfusion() ||
              t >= hi - Precision::PConfusion())
            continue;
          BOPDS_Pave pave;
          pave.SetIndex(vertex);
          pave.SetParameter(t);
          block->AppendExtPave(pave);
          changed.Add(index);
        }
      }
    }
    if (!changed.IsEmpty())
      SplitPaveBlocks(changed, false);
  }
};
} // namespace

TopoDS_Shape
splitFaces(const ShapeList &objects, const ShapeList &tools,
           const std::vector<std::pair<size_t, TopoDS_Edge>> *tracked,
           std::vector<ShapeSet> *pieces) {
  Intersections intersections;
  intersections.SetArguments(objects);
  for (const auto &tool : tools)
    intersections.AddArgument(tool);
  intersections.Perform();
  if (intersections.HasErrors())
    throw std::runtime_error("projected boundary intersection failed");
  BRepAlgoAPI_Splitter split(intersections);
  split.SetArguments(objects);
  split.SetTools(tools);
  split.Build();
  if (!split.IsDone())
    throw std::runtime_error("projected face subdivision failed");
  if (tracked && pieces)
    for (const auto &[source, edge] : *tracked) {
      if (split.IsDeleted(edge))
        continue;
      const auto &parts = split.Modified(edge);
      if (parts.IsEmpty())
        (*pieces)[source].Add(edge);
      for (const auto &part : parts)
        (*pieces)[source].Add(part);
    }
  return split.Shape();
}
} // namespace huak::space
