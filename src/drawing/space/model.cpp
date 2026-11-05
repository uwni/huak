// Construct OCCT topology from Huak geometry. The caller builds operands first.
#include "result.hxx"
#include <BRepAlgoAPI_BooleanOperation.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepLib.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Geom2d_BezierCurve.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_Circle.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Wire.hxx>
#include <algorithm>
#include <gp_Elips.hxx>
#include <stdexcept>

namespace huak::space {
namespace {
gp_Pnt xyz(const double *v) { return {v[0], v[1], v[2]}; }
TopoDS_Edge cubic(gp_Pnt a, gp_Pnt b, gp_Pnt c, gp_Pnt d) {
  TColgp_Array1OfPnt pts(1, 4);
  pts(1) = a;
  pts(2) = b;
  pts(3) = c;
  pts(4) = d;
  return BRepBuilderAPI_MakeEdge(new Geom_BezierCurve(pts));
}
TopoDS_Wire contour(const TopoDS_Shape &shape) {
  if (shape.ShapeType() == TopAbs_EDGE)
    return BRepBuilderAPI_MakeWire(TopoDS::Edge(shape));
  if (shape.ShapeType() == TopAbs_WIRE)
    return TopoDS::Wire(shape);
  throw std::invalid_argument("expected one connected curve");
}
TopoDS_Shape planarFace(const std::vector<TopoDS_Wire> &wires) {
  if (wires.empty() || !wires.front().Closed())
    throw std::invalid_argument("expected a closed planar contour");
  BRepBuilderAPI_MakeFace face(wires.front(), true);
  if (!face.IsDone())
    throw std::invalid_argument("contour does not bound a plane");
  for (size_t i = 1; i < wires.size(); ++i) {
    if (!wires[i].Closed())
      throw std::invalid_argument("open hole in planar face");
    face.Add(wires[i]);
  }
  if (!BRepCheck_Analyzer(face.Face()).IsValid())
    throw std::invalid_argument("invalid planar face boundary");
  return face.Face();
}
// Use the same section rules for drawn paths and native model edges.
TopoDS_Shape section(const TopoDS_Shape &shape, bool requireFace) {
  if (!requireFace && shape.ShapeType() == TopAbs_FACE)
    return shape;
  std::vector<TopoDS_Wire> wires;
  if (shape.ShapeType() == TopAbs_COMPOUND) {
    for (TopoDS_Iterator it(shape); it.More(); it.Next())
      wires.push_back(contour(it.Value()));
  } else {
    wires.push_back(contour(shape));
  }
  if (requireFace || (!wires.empty() && wires.front().Closed()))
    return planarFace(wires);
  return shape;
}

TopoDS_Shape readProfile(const HuakModelShape &m, Handle(Geom_Surface) surface,
                         double tolerance) {
  TopoDS_Compound compound;
  BRep_Builder builder;
  builder.MakeCompound(compound);
  auto lift = [&](HuakXY p) {
    return gp_Pnt(xyz(m.origin).XYZ() + xyz(m.u).XYZ() * p.x +
                  xyz(m.v).XYZ() * p.y);
  };
  std::vector<TopoDS_Wire> wires;
  BRepBuilderAPI_MakeWire wire;
  auto finish = [&] {
    if (wire.IsDone())
      wires.push_back(wire.Wire());
    wire = BRepBuilderAPI_MakeWire();
  };
  HuakXY start{}, here{};
  for (size_t i = 0; i < m.count; ++i) {
    const auto &cmd = m.profile[i];
    if (cmd.op == HUAK_MOVE) {
      finish();
      start = here = cmd.p[0];
      continue;
    }
    const bool bez = cmd.op == HUAK_BEZIER;
    const HuakXY end = cmd.op == HUAK_CLOSE ? start : cmd.p[bez ? 2 : 0];
    if (bez || end.x != here.x || end.y != here.y) {
      TopoDS_Edge edge;
      if (!surface.IsNull()) {
        TColgp_Array1OfPnt2d pts(1, bez ? 4 : 2);
        pts(1) = {here.x, here.y};
        if (bez) {
          pts(2) = {cmd.p[0].x, cmd.p[0].y};
          pts(3) = {cmd.p[1].x, cmd.p[1].y};
        }
        pts(pts.Upper()) = {end.x, end.y};
        edge = BRepBuilderAPI_MakeEdge(new Geom2d_BezierCurve(pts), surface);
        if (!BRepLib::BuildCurve3d(edge,
                                   std::min(tolerance, Precision::Confusion())))
          throw std::runtime_error("surface curve approximation failed");
        builder.Add(compound, edge);
      } else {
        edge =
            bez ? cubic(lift(here), lift(cmd.p[0]), lift(cmd.p[1]), lift(end))
                : BRepBuilderAPI_MakeEdge(lift(here), lift(end)).Edge();
        wire.Add(edge);
        if (!wire.IsDone())
          throw std::invalid_argument("disconnected path");
      }
    }
    here = end;
  }
  if (!surface.IsNull())
    return compound;
  finish();
  if (wires.size() == 1)
    return wires.front();
  for (const auto &w : wires)
    builder.Add(compound, w);
  return compound;
}
} // namespace

TopoDS_Shape buildShape(const HuakModelShape &m,
                        const std::vector<TopoDS_Shape> &nodes, double tol) {
  auto in = [&](size_t i) -> const TopoDS_Shape & {
    return nodes.at(m.inputs[i]);
  };
  const auto &a = m.args;
  switch (m.kind) {
  case HUAK_SPHERE:
    return BRepPrimAPI_MakeSphere(a[0]);
  case HUAK_CYLINDER:
    return BRepPrimAPI_MakeCylinder(a[0], a[1]);
  case HUAK_CONE:
    return BRepPrimAPI_MakeCone(a[0], a[1], a[2]);
  case HUAK_TORUS:
    return BRepPrimAPI_MakeTorus(a[0], a[1]);
  case HUAK_SEGMENT:
    return BRepBuilderAPI_MakeEdge(xyz(a), xyz(a + 3));
  case HUAK_CUBIC:
    return cubic(xyz(a), xyz(a + 3), xyz(a + 6), xyz(a + 9));
  case HUAK_POLYLINE:
  case HUAK_POLYGON: {
    BRepBuilderAPI_MakePolygon p;
    for (size_t i = 0; i < m.count; ++i)
      p.Add(xyz(m.points[i].xyz));
    if (m.kind == HUAK_POLYGON)
      p.Close();
    return p.Wire();
  }
  case HUAK_ELLIPSE:
  case HUAK_CIRCLE:
  case HUAK_ARC: {
    gp_Ax2 axes(xyz(m.origin), gp::DZ(), gp::DX());
    if (m.kind == HUAK_ELLIPSE) {
      if (a[1] > a[0])
        axes.SetXDirection(gp::DY());
      return BRepBuilderAPI_MakeEdge(
          gp_Elips(axes, std::max(a[0], a[1]), std::min(a[0], a[1])));
    }
    Handle(Geom_Circle) circle = new Geom_Circle(axes, a[0]);
    if (m.kind == HUAK_CIRCLE)
      return BRepBuilderAPI_MakeEdge(circle);
    double end = a[1] + a[2];
    Handle(Geom_TrimmedCurve) arc =
        new Geom_TrimmedCurve(circle, std::min(a[1], end), std::max(a[1], end));
    if (a[2] < 0)
      arc->Reverse();
    return BRepBuilderAPI_MakeEdge(arc);
  }
  case HUAK_PROFILE:
  case HUAK_FACE:
  case HUAK_EXTRUDE:
  case HUAK_REVOLVE: {
    auto profile = m.input_count ? in(0) : readProfile(m, {}, tol);
    if (m.kind == HUAK_PROFILE)
      return profile;
    profile = section(profile, m.kind == HUAK_FACE);
    if (m.kind == HUAK_EXTRUDE)
      return BRepPrimAPI_MakePrism(profile, gp_Vec(xyz(a).XYZ()));
    if (m.kind == HUAK_REVOLVE)
      return BRepPrimAPI_MakeRevol(
          profile, gp_Ax1(xyz(a), gp_Dir(xyz(a + 3).XYZ())), a[6]);
    return profile;
  }
  case HUAK_SURFACE_CURVE: {
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(in(0), TopAbs_FACE, faces);
    if (m.face < 0 || m.face >= faces.Extent())
      throw std::invalid_argument("surface face index out of range");
    return readProfile(m, BRep_Tool::Surface(TopoDS::Face(faces(m.face + 1))),
                       tol);
  }
  case HUAK_REVERSE:
    return contour(in(0)).Reversed();
  case HUAK_CLOSED: {
    auto source = contour(in(0));
    if (source.Closed())
      throw std::invalid_argument("expected an open curve");
    TopoDS_Vertex first, last;
    TopExp::Vertices(source, first, last);
    BRepBuilderAPI_MakeWire wire(source);
    wire.Add(BRepBuilderAPI_MakeEdge(last, first));
    return wire.Wire();
  }
  case HUAK_JOINED: {
    auto left = contour(in(0)), right = contour(in(1));
    TopoDS_Vertex first, last, next, end;
    TopExp::Vertices(left, first, last);
    TopExp::Vertices(right, next, end);
    if (left.Closed() || right.Closed() || last.IsNull() || next.IsNull() ||
        BRep_Tool::Pnt(last).Distance(BRep_Tool::Pnt(next)) >
            Precision::Confusion())
      throw std::invalid_argument("disconnected path endpoints");
    BRepBuilderAPI_MakeWire wire(left);
    wire.Add(right);
    return wire.Wire();
  }
  case HUAK_TRANSFORMED: {
    gp_GTrsf t(gp_Mat(a[0], a[1], a[2], a[4], a[5], a[6], a[8], a[9], a[10]),
               {a[3], a[7], a[11]});
    if (t.IsSingular())
      throw std::invalid_argument("singular transform on model");
    t.SetForm();
    if (t.Form() != gp_Other) {
      gp_Trsf similarity;
      similarity.SetValues(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8],
                           a[9], a[10], a[11]);
      return BRepBuilderAPI_Transform(in(0), similarity);
    }
    return BRepBuilderAPI_GTransform(in(0), t);
  }
  case HUAK_SWEEP:
    return BRepOffsetAPI_MakePipe(contour(in(1)), section(in(0), false));
  case HUAK_LOFT:
  case HUAK_SOLID_LOFT: {
    if (m.input_count < 2)
      throw std::invalid_argument("loft needs at least two sections");
    BRepOffsetAPI_ThruSections loft(m.kind == HUAK_SOLID_LOFT);
    for (size_t i = 0; i < m.input_count; ++i) {
      auto section = contour(in(i));
      if (m.kind == HUAK_SOLID_LOFT && !section.Closed())
        throw std::invalid_argument("solid loft needs closed sections");
      loft.AddWire(section);
    }
    loft.Build();
    return loft.Shape();
  }
  case HUAK_FUSE:
  case HUAK_COMMON:
  case HUAK_CUT: {
    TopTools_ListOfShape left, right;
    left.Append(in(0));
    right.Append(in(1));
    BRepAlgoAPI_BooleanOperation op;
    op.SetNonDestructive(true);
    op.SetArguments(left);
    op.SetTools(right);
    op.SetOperation(m.kind == HUAK_FUSE     ? BOPAlgo_FUSE
                    : m.kind == HUAK_COMMON ? BOPAlgo_COMMON
                                            : BOPAlgo_CUT);
    op.Build();
    if (!op.IsDone())
      throw std::runtime_error("model Boolean operation failed");
    op.SimplifyResult();
    return op.Shape();
  }
  default:
    throw std::invalid_argument("unknown model operation");
  }
}
} // namespace huak::space
