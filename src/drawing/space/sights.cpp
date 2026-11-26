// Where lines of sight meet faces (sights.hxx).
#include "sights.hxx"
#include "view.hxx"
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRep_Tool.hxx>
#include <BVH_Traverse.hxx>
#include <Bnd_Box.hxx>
#include <ElCLib.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <Geom_Line.hxx>
#include <IntCurveSurface_TheCSFunctionOfHInter.hxx>
#include <IntCurvesFace_Intersector.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <array>
#include <math_FunctionSetRoot.hxx>
#include <math_Matrix.hxx>
#include <math_Vector.hxx>
#include <optional>
#include <stdexcept>

namespace huak::space {
namespace {
// The tolerance with which OCCT's intersector runs its curve and surface
// solver, and how near the surface's point and the line's must then come
// for the solver to take them for a root, squared: the larger of that and
// what OCCT tells apart.
constexpr double tangency = 1e-8;
const double solved = std::max(tangency * tangency, Precision::SquareConfusion());

using Boxes = BVH_BoxSet<double, 2, Sights::Entry>;

// The entries whose boxes hold a point.
class Holding : public BVH_Traverse<double, 2, Boxes, bool> {
public:
  Holding(const gp_Pnt2d &at, int only, std::vector<Sights::Entry> &found) : at(at), only(only), found(found) {}

  bool RejectNode(const BVH_Vec2d &low, const BVH_Vec2d &high, bool &) const override {
    return outside(low, high);
  }

  bool Accept(const int index, const bool &) override {
    const Sights::Entry entry = myBVHSet->Element(index);
    const auto box = myBVHSet->Box(index);
    if ((only >= 0 && entry.face != only) || outside(box.CornerMin(), box.CornerMax()))
      return false;
    found.push_back(entry);
    return true;
  }

private:
  bool outside(const BVH_Vec2d &low, const BVH_Vec2d &high) const {
    return at.X() < low.x() || at.X() > high.x() || at.Y() < low.y() || at.Y() > high.y();
  }

  gp_Pnt2d at;
  int only;
  std::vector<Sights::Entry> &found;
};

// The box of the image of points, widened by `reach`.
BVH_Box<double, 2> imageBox(const gp_Pnt2d *points, size_t count, double reach) {
  BVH_Box<double, 2> box;
  for (size_t k = 0; k < count; ++k)
    box.Add(BVH_Vec2d(points[k].X(), points[k].Y()));
  box.Add(box.CornerMin() - BVH_Vec2d(reach, reach));
  box.Add(box.CornerMax() + BVH_Vec2d(reach, reach));
  return box;
}

// The point of a triangle nearest a point, as weights of its corners.
std::array<double, 3> nearestIn(const gp_Pnt2d &p, const gp_Pnt2d &a, const gp_Pnt2d &b, const gp_Pnt2d &c) {
  const double area = gp_Vec2d(a, b).Crossed(gp_Vec2d(a, c));
  if (std::abs(area) > gp::Resolution()) {
    const double wa = gp_Vec2d(p, b).Crossed(gp_Vec2d(p, c)) / area;
    const double wb = gp_Vec2d(p, c).Crossed(gp_Vec2d(p, a)) / area;
    if (wa >= 0 && wb >= 0 && wa + wb <= 1)
      return {wa, wb, 1 - wa - wb};
  }
  std::array<double, 3> best{1, 0, 0};
  double least = RealLast();
  const std::array<const gp_Pnt2d *, 3> corners{&a, &b, &c};
  for (int k = 0; k < 3; ++k) {
    const gp_Pnt2d &x = *corners[k], &y = *corners[(k + 1) % 3];
    if (const double away = apart(p, x, y); away < least) {
      least = away;
      const double t = along(p, x, y);
      best = {0, 0, 0};
      best[k] = 1 - t;
      best[(k + 1) % 3] = t;
    }
  }
  return best;
}

// Where a line that meets the surface at a root crosses it again nearby, as
// the surface's osculating quadric there has it: along the line, s from the
// root, the line stands g s - II(t) s² / 2 off the surface, g the sine of
// its slant to the tangent plane and II the second fundamental form along
// the line's way t in the tangent plane, so it crosses again at
// s = 2 g / II(t). Near the outline, where the two roots are close and the
// solver comes to the same one from every seed, it comes to the other from
// there. Nothing where the surface has no normal or does not bend that way.
std::optional<gp_XYZ> crossesAgain(const BRepAdaptor_Surface &surface, const gp_Lin &line, const gp_XYZ &root) {
  gp_Pnt p;
  gp_Vec su, sv, suu, svv, suv;
  surface.D2(root.X(), root.Y(), p, su, sv, suu, svv, suv);
  gp_Vec n = su.Crossed(sv);
  if (n.Magnitude() <= gp::Resolution())
    return std::nullopt;
  n.Normalize();
  const gp_Vec d(line.Direction());
  const double g = n.Dot(d);
  const gp_Vec t = d - n * g;
  // The way t in the face's parameters: a su + b sv = t.
  const double e = su.Dot(su), f = su.Dot(sv), h = sv.Dot(sv), det = e * h - f * f;
  if (!(det > 0))
    return std::nullopt;
  const double tu = su.Dot(t), tv = sv.Dot(t);
  const double a = (h * tu - f * tv) / det, b = (e * tv - f * tu) / det;
  const double bend = n.Dot(suu * (a * a) + suv * (2 * a * b) + svv * (b * b));
  if (!(std::abs(bend) > 0))
    return std::nullopt;
  const double s = 2 * g / bend;
  return gp_XYZ(root.X() + s * a, root.Y() + s * b, root.Z() + s);
}

// Whether OCCT's intersector keeps a root of the face at `uv`: in the face
// or on its boundary, as the face's least tolerance tells; or else on it as
// its greatest does, where an edge of the face passes within its greatest
// tolerance in space.
bool keeps(Sights::Face &f, const gp_Pnt2d &uv, const gp_Pnt &point) {
  TopAbs_State state = f.least->Perform(uv);
  if (state == TopAbs_OUT && f.mostTolerance > f.leastTolerance) {
    if (!f.most)
      f.most = std::make_unique<BRepTopAdaptor_FClass2d>(TopoDS::Face(f.face.Oriented(TopAbs_FORWARD)), f.mostTolerance);
    if (f.most->Perform(uv) != TopAbs_ON)
      return false;
    for (TopExp_Explorer e(f.face, TopAbs_EDGE); e.More(); e.Next()) {
      double first, last;
      const Handle(Geom_Curve) curve = BRep_Tool::Curve(TopoDS::Edge(e.Current()), first, last);
      if (curve.IsNull())
        continue;
      GeomAPI_ProjectPointOnCurve nearest(point, curve, first, last);
      if (nearest.NbPoints() > 0 && nearest.LowerDistance() <= f.spaceTolerance)
        return true;
    }
    return false;
  }
  return state == TopAbs_IN || state == TopAbs_ON;
}
} // namespace

Sights::Sights(const HuakModel &model, const HLRAlgo_Projector &projector)
    : projector(projector), rayTol(1, 3), rayLower(1, 3), rayUpper(1, 3), raySeed(1, 3), rayVal(1, 3) {
  for (size_t source = 0; source < model.shapes.size(); ++source) {
    const auto &index = model.faces[source];
    for (int k = 1; k <= index.Extent(); ++k) {
      auto f = std::make_unique<Face>();
      f->source = source;
      f->index = static_cast<size_t>(k - 1);
      f->face = TopoDS::Face(index(k));
      f->surface = new BRepAdaptor_Surface(f->face, true);
      f->geometry = BRep_Tool::Surface(f->face);
      BRepBndLib::Add(f->face, f->box, false);
      const int at = static_cast<int>(faces.size());
      const auto type = f->surface->GetType();
      if (type == GeomAbs_Plane || type == GeomAbs_Cylinder || type == GeomAbs_Cone || type == GeomAbs_Sphere ||
          type == GeomAbs_Torus) {
        f->closed = new IntCurvesFace_Intersector(f->face, Precision::Confusion());
        double x0, y0, z0, x1, y1, z1;
        f->box.Get(x0, y0, z0, x1, y1, z1);
        std::array<gp_Pnt2d, 8> corners;
        for (int c = 0; c < 8; ++c)
          projector.Project(gp_Pnt(c & 1 ? x1 : x0, c & 2 ? y1 : y0, c & 4 ? z1 : z0), corners[c]);
        boxes.Add({at, -1}, imageBox(corners.data(), corners.size(), 0));
      } else {
        const auto &s = *f->surface;
        // A surface without extent one way OCCT's intersector does not take.
        if ((s.LastUParameter() - s.FirstUParameter()) / s.UResolution(1.0) <= Precision::Confusion() ||
            (s.LastVParameter() - s.FirstVParameter()) / s.VResolution(1.0) <= Precision::Confusion())
          throw std::runtime_error("surface visibility query failed");
        double least = BRep_Tool::Tolerance(f->face), most = least;
        for (TopExp_Explorer e(f->face, TopAbs_EDGE); e.More(); e.Next()) {
          least = std::min(least, BRep_Tool::Tolerance(TopoDS::Edge(e.Current())));
          most = std::max(most, BRep_Tool::Tolerance(TopoDS::Edge(e.Current())));
        }
        f->leastTolerance = std::max({s.UResolution(least), s.VResolution(least), Precision::Confusion()});
        f->mostTolerance = std::max({s.UResolution(most), s.VResolution(most), Precision::Confusion()});
        f->spaceTolerance = most;
        f->least = std::make_unique<BRepTopAdaptor_FClass2d>(TopoDS::Face(f->face.Oriented(TopAbs_FORWARD)),
                                                             f->leastTolerance);
        f->layOut(projector);
        const size_t nv = f->vs.size();
        for (size_t i = 0; i + 1 < f->us.size(); ++i)
          for (size_t j = 0; j + 1 < nv; ++j) {
            const size_t cell = i * (nv - 1) + j;
            const gp_Pnt2d corners[4] = {f->images[f->at(i, j)], f->images[f->at(i + 1, j)],
                                         f->images[f->at(i + 1, j + 1)], f->images[f->at(i, j + 1)]};
            boxes.Add({at, static_cast<int>(cell)}, imageBox(corners, 4, f->reach[cell]));
          }
      }
      faces.push_back(std::move(f));
    }
  }
  first.assign(model.shapes.size() + 1, faces.size());
  for (size_t k = faces.size(); k-- > 0;)
    first[faces[k]->source] = k;
  for (size_t source = model.shapes.size(); source-- > 0;)
    first[source] = std::min(first[source], first[source + 1]);
  boxes.Build();
}

Sights::~Sights() = default;

void Sights::collect(const gp_Pnt2d &at, int only) {
  held.clear();
  Holding holding(at, only, held);
  holding.SetBVHSet(&boxes);
  holding.Select();
  std::sort(held.begin(), held.end(),
            [](const Entry &a, const Entry &b) { return a.face != b.face ? a.face < b.face : a.cell < b.cell; });
}

void Sights::meet(const gp_Pnt2d &at, std::vector<Sight> &out) {
  out.clear();
  collect(at, -1);
  if (held.empty())
    return;
  const gp_Lin line = projector.Shoot(at.X(), at.Y());
  for (size_t k = 0; k < held.size();) {
    size_t end = k + 1;
    while (end < held.size() && held[end].face == held[k].face)
      ++end;
    meetFace(*faces[static_cast<size_t>(held[k].face)], line, at, held.data() + k, held.data() + end, out);
    k = end;
  }
  // Each shape's in order along the line, as OCCT's shape intersector sorts
  // them.
  std::stable_sort(out.begin(), out.end(),
                   [](const Sight &a, const Sight &b) { return a.source != b.source ? a.source < b.source : a.w < b.w; });
}

void Sights::meet(size_t source, size_t face, const gp_Pnt2d &at, std::vector<Sight> &out) {
  out.clear();
  const size_t k = first.at(source) + face;
  if (k >= first.at(source + 1))
    throw std::out_of_range("face index out of range");
  collect(at, static_cast<int>(k));
  if (held.empty())
    return;
  meetFace(*faces[k], projector.Shoot(at.X(), at.Y()), at, held.data(), held.data() + held.size(), out);
  std::stable_sort(out.begin(), out.end(), [](const Sight &a, const Sight &b) { return a.w < b.w; });
}

void Sights::meetFace(Face &f, const gp_Lin &line, const gp_Pnt2d &at, const Entry *from, const Entry *to,
                      std::vector<Sight> &out) {
  if (!f.closed.IsNull()) {
    f.closed->Perform(line, -RealLast(), RealLast());
    if (!f.closed->IsDone())
      throw std::runtime_error("surface visibility query failed");
    for (int j = 1; j <= f.closed->NbPnt(); ++j)
      out.push_back({f.source, f.index, f.closed->Pnt(j), f.closed->UParameter(j), f.closed->VParameter(j),
                     f.closed->WParameter(j)});
    return;
  }
  // Along the line, where it is a point of the line; the part of the line
  // through the face's box, a twentieth longer at either end, as OCCT's
  // intersector takes it.
  const gp_Vec way(line.Direction());
  const auto along = [&](const gp_Pnt &p) { return gp_Vec(line.Location(), p).Dot(way); };
  double x0, y0, z0, x1, y1, z1;
  f.box.Get(x0, y0, z0, x1, y1, z1);
  double w0 = RealLast(), w1 = -RealLast();
  for (int c = 0; c < 8; ++c) {
    const double w = along(gp_Pnt(c & 1 ? x1 : x0, c & 2 ? y1 : y0, c & 4 ? z1 : z0));
    w0 = std::min(w0, w);
    w1 = std::max(w1, w);
  }
  const double pad = 0.05 * (w1 - w0) + Precision::Confusion();
  // OCCT's curve and surface function and its solver, with the tolerances
  // and the test for a root its exact intersector sets. The intersector
  // runs the solver over the whole face and, failing, again from either
  // end of the line; a seed in a cell needs only the first. Bounds of a few
  // cells would not do: across a sliver of a face, as a loft leaves where
  // its sections' joins nearly meet, a parameter moves the surface so
  // little that the solver's steps along it run far beyond them.
  if (rayLine.IsNull()) {
    rayLine = new Geom_Line(line);
    rayCurve = new GeomAdaptor_Curve(rayLine);
  } else {
    rayLine->SetLin(line);
    rayCurve->Reset();
    rayCurve->Load(rayLine);
  }
  IntCurveSurface_TheCSFunctionOfHInter function(f.surface, rayCurve);
  rayTol(1) = f.surface->UResolution(Precision::Confusion());
  rayTol(2) = f.surface->VResolution(Precision::Confusion());
  rayTol(3) = Precision::Confusion();
  if (!raySolver)
    raySolver = std::make_unique<math_FunctionSetRoot>(function, rayTol);
  else
    raySolver->SetTolerance(rayTol);
  rayLower(1) = f.us.front(), rayUpper(1) = f.us.back();
  rayLower(2) = f.vs.front(), rayUpper(2) = f.vs.back();
  rayLower(3) = w0 - pad;
  rayUpper(3) = w1 + pad;
  const auto run = [&](const gp_XYZ &guess) -> std::optional<gp_XYZ> {
    raySeed(1) = guess.X(), raySeed(2) = guess.Y(), raySeed(3) = guess.Z();
    raySolver->Perform(function, raySeed, rayLower, rayUpper);
    if (!raySolver->IsDone())
      return std::nullopt;
    const math_Vector &x = raySolver->Root();
    if (!function.Value(x, rayVal) || rayVal.Norm2() > solved)
      return std::nullopt;
    return gp_XYZ(x(1), x(2), x(3));
  };
  const size_t start = out.size(), nv = f.vs.size();
  // Keeps a root, unless a root kept already is the same: the solver stops
  // within what OCCT tells apart of a root, so roots that two seeds reach
  // within twice that are one.
  const auto keep = [&](const gp_XYZ &found) {
    const gp_Pnt point = ElCLib::Value(found.Z(), line);
    if (std::none_of(out.begin() + static_cast<std::ptrdiff_t>(start), out.end(),
                     [&](const Sight &s) { return s.point.Distance(point) <= 2 * Precision::Confusion(); }) &&
        keeps(f, gp_Pnt2d(found.X(), found.Y()), point))
      out.push_back({f.source, f.index, point, found.X(), found.Y(), found.Z()});
  };
  for (const Entry *e = from; e != to; ++e) {
    const size_t cell = static_cast<size_t>(e->cell), i = cell / (nv - 1), j = cell % (nv - 1);
    const size_t corner[4] = {f.at(i, j), f.at(i + 1, j), f.at(i + 1, j + 1), f.at(i, j + 1)};
    const double cu[4] = {f.us[i], f.us[i + 1], f.us[i + 1], f.us[i]};
    const double cv[4] = {f.vs[j], f.vs[j], f.vs[j + 1], f.vs[j + 1]};
    bool seeded = false;
    std::optional<gp_XYZ> prevFound;
    for (const auto &t : {std::array<int, 3>{0, 1, 2}, std::array<int, 3>{0, 2, 3}}) {
      const auto weight = nearestIn(at, f.images[corner[t[0]]], f.images[corner[t[1]]], f.images[corner[t[2]]]);
      gp_XY near(0, 0);
      gp_XYZ guess(0, 0, 0);
      for (int k = 0; k < 3; ++k) {
        near += weight[k] * f.images[corner[t[k]]].XY();
        guess += weight[k] * gp_XYZ(cu[t[k]], cv[t[k]], along(f.nodes[corner[t[k]]]));
      }
      if (gp_Pnt2d(near).Distance(at) > f.reach[cell])
        continue;
      seeded = true;
      const auto found = run(guess);
      if (!found)
        continue;
      if (prevFound && std::abs(found->X() - prevFound->X()) <= rayTol(1) &&
          std::abs(found->Y() - prevFound->Y()) <= rayTol(2) &&
          std::abs(found->Z() - prevFound->Z()) <= rayTol(3))
        continue;
      prevFound = found;
      keep(*found);
      // The quadric tells of the surface about the root, so a second
      // crossing it puts more than a cell beyond the seed's cell tells
      // nothing. One at a side of the face may be put a little beyond it;
      // the solver then starts from the nearest point of the face.
      const auto again = crossesAgain(*f.surface, line, *found);
      const double du = cu[1] - cu[0], dv = cv[2] - cv[1];
      if (again && again->X() >= cu[0] - du && again->X() <= cu[1] + du && again->Y() >= cv[0] - dv &&
          again->Y() <= cv[2] + dv)
        if (const auto other = run(gp_XYZ(std::clamp(again->X(), rayLower(1), rayUpper(1)),
                                          std::clamp(again->Y(), rayLower(2), rayUpper(2)), again->Z())))
          keep(*other);
    }
    // Where the line grazes the surface, it crosses it twice, close together
    // on either side of the outline, where the projection folds the surface;
    // and the solver, which folds the same way, keeps to the side it starts
    // on (as t² = b does to the root with the sign of its start), where the
    // root may lie beyond a side of the face. So where the cell's corners
    // face the line both ways, the outline crossing it, the solver also
    // starts from the corners, on either side.
    if (!seeded)
      continue;
    int ways = 0;
    for (const size_t k : corner) {
      const auto &normal = f.normals[k];
      const double facing = normal ? normal->Dot(line.Direction()) : 0;
      ways |= facing > 0 ? 1 : facing < 0 ? 2 : 3;
    }
    if (ways == 3)
      for (int k = 0; k < 4; ++k)
        if (const auto found = run(gp_XYZ(cu[k], cv[k], along(f.nodes[corner[k]]))))
          keep(*found);
  }
}
} // namespace huak::space
