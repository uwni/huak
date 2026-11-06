#pragma once
#include "projection.h"
#include <HLRAlgo_Projector.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS_Edge.hxx>
#include <memory>
#include <optional>
#include <vector>

namespace huak::space {
TopoDS_Shape buildShape(const HuakModelShape &,
                        const std::vector<TopoDS_Shape> &, double tolerance);
struct Result {
  std::vector<HuakPathCommand> commands;
  std::vector<HuakProjectedLine> lines;
  std::vector<HuakProjectedFace> faces;
  std::vector<HuakSpot> lobes;
};
void writeEdge(Result &, const TopoDS_Edge &, double tolerance,
               bool move = true);
TopoDS_Edge projected(const TopoDS_Edge &, const HLRAlgo_Projector &,
                      double tolerance);
struct Feature {
  size_t source;
  int kind;
  std::optional<bool> own_visible; // HLR relative to the source shape alone
  TopoDS_Edge edge;
  ptrdiff_t other_source = -1;
};
struct Hit {
  double depth;
  size_t source;
  int face;
  gp_Pnt2d uv;
};
// Each shape's face intersector is loaded once per projection. The scratch
// hit list is ordered front to back and reused for both face cells and edges.
struct Surfaces {
  explicit Surfaces(const std::vector<TopoDS_Shape> &shapes);
  const std::vector<Hit> &along(const gp_Lin &, const gp_Dir &toward_eye);
  std::vector<std::unique_ptr<IntCurvesFace_ShapeIntersector>> probes;
  std::vector<TopTools_IndexedMapOfShape> faces;
  std::vector<Hit> hits;
  size_t count = 0;
};
void drawEdges(Result &, Surfaces &, const std::vector<Feature> &,
               const HLRAlgo_Projector &, const gp_Dir &, double tolerance,
               std::vector<TopoDS_Edge> *cell_boundaries);
void intersectShapes(const std::vector<TopoDS_Shape> &, const Surfaces &,
                     std::vector<Feature> &);
void projectFaces(Result &, Surfaces &, const std::vector<TopoDS_Shape> &,
                  const std::vector<TopoDS_Edge> &cell_boundaries,
                  const HLRAlgo_Projector &, const gp_Dir &toward_eye,
                  const HuakLight *, double tolerance);
} // namespace huak::space
