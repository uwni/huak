#pragma once
// Declarations shared by the OCCT adapter's translation units. The adapter
// builds shapes and answers queries about them; Huak decides what to draw.
#include "projection.h"
#include <Geom2d_Curve.hxx>
#include <HLRAlgo_Projector.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <NCollection_IndexedMap.hxx>
#include <NCollection_List.hxx>
#include <NCollection_Map.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <memory>
#include <utility>
#include <vector>

namespace huak::space {
using ShapeList = NCollection_List<TopoDS_Shape>;
using ShapeIndex =
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>;
using ShapeSet = NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher>;

TopoDS_Shape buildShape(const HuakModelShape &,
                        const std::vector<TopoDS_Shape> &, double tolerance);
// The image of an edge in the projection plane z = 0; null where it collapses
// to a point.
TopoDS_Edge projected(const TopoDS_Edge &, const HLRAlgo_Projector &,
                      double tolerance);
// An image edge's curve as a planar curve, with the same parameter.
Handle(Geom2d_Curve) inPlane(const TopoDS_Edge &);
// Appends an image edge as path commands within `tolerance`, starting with a
// move when `move` is set.
void writeEdge(std::vector<HuakPathCommand> &, const TopoDS_Edge &,
               double tolerance, bool move = true);
// Appends each wire of a planar face as a closed path.
void writeFace(std::vector<HuakPathCommand> &, TopoDS_Face, double tolerance);
// Splits planar `objects` by image edges. `pieces[source]` receives what
// becomes of each tracked edge of shape `source`.
TopoDS_Shape
splitFaces(const ShapeList &objects, const ShapeList &tools,
           const std::vector<std::pair<size_t, TopoDS_Edge>> *tracked = nullptr,
           std::vector<ShapeSet> *pieces = nullptr);
// Appends the images of the curves on `face` where the normal makes `angle`
// with `direction`.
void traceContour(const TopoDS_Face &, gp_Dir direction, double angle,
                  const HLRAlgo_Projector &, double tolerance,
                  ShapeList &images);
} // namespace huak::space

// The root shapes of one build, their faces, and an intersector for each
// shape with faces.
struct HuakModel {
  std::vector<TopoDS_Shape> shapes;
  std::vector<huak::space::ShapeIndex> faces;
  std::vector<std::unique_ptr<IntCurvesFace_ShapeIntersector>> probes;
  double tolerance = 0;
};
