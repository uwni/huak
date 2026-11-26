// The closed loops the arcs bound, as paths and as faces with their bounds
// and moments.
#include "view.hxx"
#include <Geom2d_BezierCurve.hxx>
#include <Geom2d_Line.hxx>
#include <Geom_Plane.hxx>
#include <NCollection_Array1.hxx>
#include <Precision.hxx>

namespace {
HuakBox boxOf(const Bnd_Box &box) {
  HuakBox result{};
  result.empty = box.IsVoid();
  if (!result.empty) {
    double z0, z1;
    box.Get(result.x0, result.y0, z0, result.x1, result.y1, z1);
  }
  return result;
}

// An arc's edge, running the way the arc is turned.
TopoDS_Edge edgeOf(HuakView *view, const HuakTurnedArc &turned) {
  const auto &arc = element(view->arcs, turned.arc, "arc");
  return TopoDS::Edge(arc.edge.Oriented(turned.reversed ? TopAbs_REVERSED : TopAbs_FORWARD));
}

// A planar face carrying the 2D line and cubic Bézier pcurves of a region's
// closed path commands, so OCCT's non-adaptive BRepGProp integrates each
// degree-<=3 edge exactly without adaptive Kronrod refinement over multi-knot
// B-splines.
TopoDS_Face faceFromCommands(const Handle(Geom_Plane) & plane, const HuakPathCommand *commands, size_t count) {
  BRep_Builder builder;
  TopoDS_Face face;
  builder.MakeFace(face, plane, Precision::Confusion());
  TopoDS_Wire wire;
  bool inWire = false;
  gp_Pnt2d first(0, 0), current(0, 0);
  const auto addLine = [&](const gp_Pnt2d &a, const gp_Pnt2d &b) {
    const gp_Vec2d delta(a, b);
    const double length = delta.Magnitude();
    if (!(length > gp::Resolution()))
      return;
    TopoDS_Edge edge;
    builder.MakeEdge(edge);
    builder.UpdateEdge(edge, new Geom2d_Line(a, gp_Dir2d(delta)), face, Precision::Confusion());
    builder.Range(edge, face, 0.0, length);
    builder.Add(wire, edge);
  };
  for (size_t i = 0; i < count; ++i) {
    const auto &cmd = commands[i];
    if (cmd.op == HUAK_MOVE) {
      if (inWire)
        builder.Add(face, wire);
      builder.MakeWire(wire);
      inWire = true;
      first = current = gp_Pnt2d(cmd.p[0].x, cmd.p[0].y);
    } else if (cmd.op == HUAK_LINE) {
      const gp_Pnt2d next(cmd.p[0].x, cmd.p[0].y);
      addLine(current, next);
      current = next;
    } else if (cmd.op == HUAK_BEZIER) {
      NCollection_Array1<gp_Pnt2d> poles(1, 4);
      poles(1) = current;
      poles(2) = gp_Pnt2d(cmd.p[0].x, cmd.p[0].y);
      poles(3) = gp_Pnt2d(cmd.p[1].x, cmd.p[1].y);
      poles(4) = gp_Pnt2d(cmd.p[2].x, cmd.p[2].y);
      TopoDS_Edge edge;
      builder.MakeEdge(edge);
      builder.UpdateEdge(edge, new Geom2d_BezierCurve(poles), face, Precision::Confusion());
      builder.Range(edge, face, 0.0, 1.0);
      builder.Add(wire, edge);
      current = poles(4);
    } else if (cmd.op == HUAK_CLOSE) {
      addLine(current, first);
      if (inWire) {
        builder.Add(face, wire);
        inWire = false;
      }
    }
  }
  if (inWire)
    builder.Add(face, wire);
  return face;
}

// The closed loops of a set of arcs that bound a region lying to their left
// as they are turned, each an arc after another around it.
//
// The arcs leave each point as often as they reach it, so following any
// unused arc from each point reached runs them all in closed paths; each
// time the path comes back to a point it has passed, the arcs since are one
// loop, which passes no point twice. Which arc follows which where several
// leave a point does not change what the loops wind around.
std::vector<std::vector<HuakTurnedArc>> loopsOf(HuakView *view, const HuakTurnedArc *arcs, size_t count) {
  // An arc as it is turned, between the points it leaves and reaches.
  struct Turned {
    HuakTurnedArc arc;
    size_t tail, head;
    bool used;
  };
  ShapeIndex points;
  std::vector<Turned> turned;
  turned.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    const auto &arc = element(view->arcs, arcs[i].arc, "arc");
    TopoDS_Vertex tail, head;
    TopExp::Vertices(arc.edge, tail, head);
    if (arcs[i].reversed)
      std::swap(tail, head);
    turned.push_back({arcs[i], static_cast<size_t>(points.Add(tail)), static_cast<size_t>(points.Add(head)), false});
  }
  const size_t nv = static_cast<size_t>(points.Extent()) + 1;
  std::vector<size_t> end(nv, 0);
  for (const auto &t : turned)
    ++end[t.tail];
  size_t total = 0;
  for (size_t v = 0; v < nv; ++v) {
    total += end[v];
    end[v] = total;
  }
  std::vector<size_t> cursor = end;
  std::vector<size_t> outgoing(total);
  for (size_t i = 0; i < turned.size(); ++i)
    outgoing[--cursor[turned[i].tail]] = i;
  std::vector<std::vector<HuakTurnedArc>> loops;
  std::vector<size_t> path;
  constexpr size_t unseen = std::numeric_limits<size_t>::max();
  std::vector<size_t> passed(nv, unseen);
  for (size_t first = 0; first < turned.size(); ++first) {
    if (turned[first].used)
      continue;
    size_t at = turned[first].tail;
    path.clear();
    passed[at] = 0;
    for (;;) {
      size_t &lo = cursor[at];
      const size_t hi = end[at];
      while (lo < hi && turned[outgoing[lo]].used)
        ++lo;
      if (lo == hi) {
        if (!path.empty())
          throw std::runtime_error("the arcs bounding a region do not close");
        passed[at] = unseen;
        break;
      }
      const size_t next = outgoing[lo++];
      turned[next].used = true;
      path.push_back(next);
      at = turned[next].head;
      if (passed[at] == unseen) {
        passed[at] = path.size();
        continue;
      }
      const size_t loop = passed[at];
      loops.emplace_back();
      loops.back().reserve(path.size() - loop);
      for (size_t i = loop; i < path.size(); ++i)
        loops.back().push_back(turned[path[i]].arc);
      for (size_t i = loop; i + 1 < path.size(); ++i)
        passed[turned[path[i]].head] = unseen;
      path.resize(loop);
    }
  }
  return loops;
}

// Appends a loop of image edges as one closed path.
void writeLoop(HuakView *view, std::vector<HuakPathCommand> &commands, const std::vector<HuakTurnedArc> &loop,
               double tolerance) {
  const size_t start = commands.size();
  for (const auto &turned : loop)
    writeEdge(commands, edgeOf(view, turned), tolerance, commands.size() == start);
  // Both ends of a loop are one point. Independent evaluations of it must
  // not leave a microscopic closing edge.
  auto &last = commands.back();
  last.p[last.op == HUAK_BEZIER ? 2 : 0] = commands[start].p[0];
  commands.push_back({HUAK_CLOSE, {}});
}

// How many times a loop turns about, as the arrangement tells it: along each
// arc between where it leaves the vertices at its ends, and through each
// vertex straight to its point and out again. Beyond its reach the arcs
// that meet at a vertex stand apart, no arc enters another vertex, and no
// vertex reaches another, so that path passes no point twice and turns
// once about: counterclockwise around a region, clockwise around a hole.
// Along each segment of its polyline an arc heads within `turning` of the
// chord, so the chords turn as the arc does; an arc leaves a vertex
// outward, within a right angle of the line from the vertex's point; and at
// that point the order in which the arcs leave decides the turn, as it does
// for the cells. The arcs' own ends tell nothing of it where the vertices
// reach as far as the arcs stand apart: two straight arcs between the same
// two vertices are one segment, run there and back.
int windingOf(HuakView *view, const std::vector<HuakTurnedArc> &loop) {
  bool hasPoint = false, hasWay = false;
  gp_Pnt2d firstPoint, prevPoint;
  double firstWay = 0, prevWay = 0, turns = 0;
  // The way of each chord, and the turn from each to the next, within a
  // half turn; a point that stands where the one before it does makes no
  // chord.
  const auto step = [&](const gp_Pnt2d &a, const gp_Pnt2d &b) {
    const gp_Vec2d chord(a, b);
    if (chord.SquareMagnitude() > 0) {
      const double way = std::atan2(chord.Y(), chord.X());
      if (hasWay)
        turns += std::remainder(way - prevWay, 2 * M_PI);
      else
        firstWay = way;
      prevWay = way;
      hasWay = true;
    }
  };
  const auto visit = [&](const gp_Pnt2d &p) {
    if (!hasPoint) {
      firstPoint = prevPoint = p;
      hasPoint = true;
      return;
    }
    step(prevPoint, p);
    prevPoint = p;
  };
  for (const auto &turned : loop) {
    const auto &arc = element(view->arcs, turned.arc, "arc");
    const double from = turned.reversed ? arc.headLeaves : arc.tailLeaves;
    const double to = turned.reversed ? arc.tailLeaves : arc.headLeaves;
    visit(arc.curve->Value(from));
    // The polyline's points between, the way the loop runs.
    const size_t n = arc.at.size();
    const double lo = std::min(from, to), hi = std::max(from, to);
    for (size_t i = 0; i < n; ++i) {
      const size_t j = turned.reversed ? n - 1 - i : i;
      if (lo < arc.at[j] && arc.at[j] < hi)
        visit(arc.points[j]);
    }
    visit(arc.curve->Value(to));
    visit(turned.reversed ? arc.tail : arc.head);
  }
  if (hasPoint)
    step(prevPoint, firstPoint);
  if (hasWay)
    turns += std::remainder(firstWay - prevWay, 2 * M_PI);
  return static_cast<int>(std::lround(turns / (2 * M_PI)));
}
} // namespace

namespace huak::space::entry {
int fill(HuakView *view, const size_t *offsets, const HuakTurnedArc *arcs, size_t count, double tolerance,
         HuakPaths *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(offsets, "offsets");
    requireArray(arcs, offsets[count], "arcs");
    require(out, "out");
    auto &starts = view->result(view->indices);
    auto &commands = view->result(view->paths);
    starts.reserve(count + 1);
    starts.push_back(0);
    for (size_t k = 0; k < count; ++k) {
      if (offsets[k] > offsets[k + 1])
        throw InvalidArgument("arc sets out of order");
      for (const auto &loop : loopsOf(view, arcs + offsets[k], offsets[k + 1] - offsets[k]))
        writeLoop(view, commands, loop, tolerance);
      starts.push_back(commands.size());
    }
    *out = {starts.data(), commands.data(), count};
  });
}

int regions(HuakView *view, const size_t *offsets, const HuakTurnedArc *arcs, size_t count, double tolerance,
            int compute_moments, HuakRegions *out, char *error, size_t capacity) {
  return guarded(error, capacity, [&] {
    require(view, "view");
    require(offsets, "offsets");
    requireArray(arcs, offsets[count], "arcs");
    require(out, "out");
    auto &sets = view->result(view->indices);
    auto &starts = view->result(view->indices);
    auto &commands = view->result(view->paths);
    auto &boxes = view->result(view->regionBoxes);
    std::vector<HuakMoments> *measures = compute_moments ? &view->result(view->regionMoments) : nullptr;
    sets.reserve(count + 1);
    starts.reserve(count + 1);
    boxes.reserve(count);
    if (measures)
      measures->reserve(count);
    sets.push_back(0);
    starts.push_back(0);
    const gp_Pln plane(gp::XOY());
    const Handle(Geom_Plane) flat = measures ? new Geom_Plane(gp::XOY()) : Handle(Geom_Plane)();
    for (size_t k = 0; k < count; ++k) {
      if (offsets[k] > offsets[k + 1])
        throw InvalidArgument("arc sets out of order");
      // Each loop by how it turns about: around a region, a face of its
      // own; around a hole, the wire of a hole in the region it lies in
      // innermost. Each has a point of one of its arcs clear of the
      // vertices, beyond the arcs' tolerances, where it stands apart from
      // every other loop's arcs.
      struct Bound {
        TopoDS_Wire wire;
        gp_Pnt2d point;
        TopoDS_Face face;
        std::unique_ptr<BRepTopAdaptor_FClass2d> classifier;
        std::vector<size_t> holes;
      };
      std::vector<Bound> outer, inner;
      for (const auto &loop : loopsOf(view, arcs + offsets[k], offsets[k + 1] - offsets[k])) {
        const int winding = windingOf(view, loop);
        if (winding != 1 && winding != -1)
          throw std::runtime_error("the arcs around a region do not turn once about it");
        BRepBuilderAPI_MakeWire wire;
        for (const auto &turned : loop)
          wire.Add(edgeOf(view, turned));
        if (!wire.IsDone())
          throw std::runtime_error("cannot join the arcs around a region");
        const auto &first = element(view->arcs, loop.front().arc, "arc");
        Bound bound{wire.Wire(), first.curve->Value(first.middle), {}, nullptr, {}};
        if (winding > 0)
          bound.face = BRepBuilderAPI_MakeFace(plane, bound.wire, false);
        (winding > 0 ? outer : inner).push_back(std::move(bound));
      }
      // Whether a point clear of the vertices of one loop lies within a
      // region's loop. The loops of a region cross nowhere and their arcs
      // stand apart, so such a point is never within the tolerances of
      // another loop's arcs: where OCCT finds it there, the arcs are not
      // what the arrangement tells.
      const auto inside = [&](Bound &bound, const gp_Pnt2d &point) {
        if (!bound.classifier)
          bound.classifier = std::make_unique<BRepTopAdaptor_FClass2d>(bound.face, Precision::PConfusion());
        const TopAbs_State state = bound.classifier->Perform(point);
        if (state != TopAbs_IN && state != TopAbs_OUT)
          throw std::runtime_error("a point of a region's bound lies on another of its bounds");
        return state == TopAbs_IN;
      };
      for (size_t h = 0; h < inner.size(); ++h) {
        std::vector<size_t> around;
        for (size_t o = 0; o < outer.size(); ++o)
          if (inside(outer[o], inner[h].point))
            around.push_back(o);
        // The innermost of the loops around it: the one inside all others.
        const auto innermost = std::find_if(around.begin(), around.end(), [&](size_t o) {
          return std::all_of(around.begin(), around.end(),
                             [&](size_t other) { return other == o || inside(outer[other], outer[o].point); });
        });
        if (innermost == around.end())
          throw std::runtime_error("a hole in a region lies in none of its regions");
        outer[*innermost].holes.push_back(h);
      }
      for (const auto &bound : outer) {
        TopoDS_Face region = bound.face;
        if (!bound.holes.empty()) {
          BRepBuilderAPI_MakeFace holed(bound.face);
          for (const size_t h : bound.holes)
            holed.Add(inner[h].wire);
          region = holed.Face();
        }
        const size_t regionStart = commands.size();
        writeFace(commands, region, tolerance);
        starts.push_back(commands.size());
        Bnd_Box box;
        BRepBndLib::Add(region, box);
        const HuakBox b = boxOf(box);
        boxes.push_back(b);
        if (measures) {
          const gp_Pnt origin = b.empty ? gp::Origin() : gp_Pnt(0.5 * (b.x0 + b.x1), 0.5 * (b.y0 + b.y1), 0.0);
          GProp_GProps props(origin);
          const TopoDS_Face cubic =
              faceFromCommands(flat, commands.data() + regionStart, commands.size() - regionStart);
          BRepGProp::SurfaceProperties(cubic, props);
          if (!(props.Mass() > 0)) {
            props = GProp_GProps(origin);
            BRepGProp::SurfaceProperties(region, props, 1e-7);
          }
          HuakMoments result{};
          result.area = props.Mass();
          copy(props.CentreOfMass().XYZ(), result.center);
          const GProp_PrincipalProps principal = props.PrincipalProperties();
          principal.Moments(result.moments[0], result.moments[1], result.moments[2]);
          copy(principal.FirstAxisOfInertia().XYZ(), result.axes[0]);
          copy(principal.SecondAxisOfInertia().XYZ(), result.axes[1]);
          copy(principal.ThirdAxisOfInertia().XYZ(), result.axes[2]);
          measures->push_back(result);
        }
      }
      sets.push_back(boxes.size());
    }
    *out = {sets.data(), starts.data(), commands.data(), boxes.data(), measures ? measures->data() : nullptr, count};
  });
}
} // namespace huak::space::entry
