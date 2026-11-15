// Contours where a face's normal makes a constant angle with a direction.
#include "space.hxx"
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepTopAdaptor_Tool.hxx>
#include <Contap_Contour.hxx>
#include <HLRTopoBRep_DSFiller.hxx>
#include <HLRTopoBRep_Data.hxx>
#include <NCollection_DataMap.hxx>
#include <TopoDS.hxx>
#include <cmath>
#include <stdexcept>

namespace huak::space {
// A draft contour is the locus of a constant angle between the surface
// normal and a fixed direction. OCCT trims it against the actual face.
void traceContour(const TopoDS_Face &face, gp_Dir direction, double angle,
                  const HLRAlgo_Projector &projector, double tolerance,
                  ShapeList &images) {
  if (face.Orientation() == TopAbs_REVERSED)
    direction.Reverse();
  Contap_Contour contour;
  contour.Init(gp_Vec(direction), angle - M_PI / 2);
  HLRTopoBRep_Data data;
  NCollection_DataMap<TopoDS_Shape, BRepTopAdaptor_Tool, TopTools_ShapeMapHasher>
      tools;
  HLRTopoBRep_DSFiller::Insert(face, contour, data, tools, 0);
  if (!contour.IsDone())
    throw std::runtime_error("cannot trace lighting contour");
  auto append = [&](const TopoDS_Edge &edge) {
    auto curve = projected(edge, projector, tolerance);
    if (!curve.IsNull())
      images.Append(curve);
  };
  if (data.FaceHasIntL(face))
    for (const auto &edge : data.FaceIntL(face))
      append(TopoDS::Edge(edge));
  // The HLR data structure stores intervals between vertices. A complete
  // analytic contour wholly inside its face can have no trimming vertices.
  for (int i = 1; i <= contour.NbLines(); ++i) {
    const auto &line = contour.Line(i);
    if (!line.NbVertex() && line.TypeContour() == Contap_Circle)
      append(BRepBuilderAPI_MakeEdge(line.Circle()));
  }
}
} // namespace huak::space
