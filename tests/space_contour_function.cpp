// The contour function the tracer computes against OCCT's own: on faces of
// every kind of surface OCCT distinguishes, for each kind of contour, the
// value and its gradient at many points must equal Contap_SurfFunction's
// bit for bit. Should OCCT change how it computes them, this fails, and
// whether to follow is a decision to make.
//
// And the bound on its rounding against the rounding there is: the bound
// takes OCCT's point and normal as exact and covers the arithmetic done on
// them, so at every point the value must lie within it of the function's
// exact value at that point and normal.
#include "../src/drawing/space/contour_function.hxx"
#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <Contap_SurfFunction.hxx>
#include <Contap_SurfProps.hxx>
#include <GC_MakeSegment.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BezierSurface.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_OffsetSurface.hxx>
#include <Geom_Plane.hxx>
#include <Geom_SphericalSurface.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_ToroidalSurface.hxx>
#include <NCollection_Array2.hxx>
#include <TopoDS_Face.hxx>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {
using huak::space::contour::ContourFunction;

bool same(double a, double b) {
  std::uint64_t x, y;
  std::memcpy(&x, &a, sizeof x);
  std::memcpy(&y, &b, sizeof y);
  return x == y;
}

// A sum of doubles kept exact term by term: a + b = s + e and a b = p + e
// exactly, s and p the computed sum and product (D. E. Knuth, The Art of
// Computer Programming 2, 3rd ed., section 4.2.2, Theorem B; T. J. Dekker,
// "A floating-point technique for extending the available precision",
// Numer. Math. 18 (1971) 224-242, the product's error here by a fused
// multiply-add).
struct Terms {
  std::vector<double> terms;
  void add(double a) { terms.push_back(a); }
  void sum(double a, double b) {
    const double s = a + b, z = s - a;
    terms.push_back(s);
    terms.push_back((a - (s - z)) + (b - z));
  }
  void product(double a, double b) {
    const double p = a * b;
    terms.push_back(p);
    terms.push_back(std::fma(a, b, -p));
  }
  // The sum, as Sum2 gives it, the cascaded sum and its errors' sum (T.
  // Ogita, S. M. Rump and S. Oishi, "Accurate sum and dot product", SIAM J.
  // Sci. Comput. 26 (2005) 1955-1988, Algorithm 4.4): within u of it and
  // gamma_(n-1)^2 of the terms' magnitudes, both far below what is measured
  // with it here. Without the last rounding, as a high and a low part.
  std::pair<double, double> parts() const {
    double s = 0, e = 0;
    for (const double a : terms) {
      const double t = s + a, z = t - s;
      e += (s - (t - z)) + (a - z);
      s = t;
    }
    return {s, e};
  }
  double total() const {
    const auto [s, e] = parts();
    return s + e;
  }
};

// How far the value read at (u, v) lies from the function's exact value at
// OCCT's point and normal there, over the bound read with it: f m - X summed
// exactly, X being the function's numerator, over m times the bound.
double overBound(const ContourFunction &function, const ContourFunction::Reading &reading,
                 const Handle(Adaptor3d_Surface) & surface, double u, double v, int kind, const gp_Dir &direction,
                 const gp_Pnt &eye, double angle) {
  gp_Pnt point;
  gp_Vec normal;
  Contap_SurfProps::Normale(surface, u, v, point, normal);
  const double m = function.meanLength();
  Terms off;
  off.product(reading.value, m);
  if (kind == 1) {
    // N.(P - E), the difference exactly a sum of two doubles.
    for (int k = 1; k <= 3; ++k) {
      Terms difference;
      difference.sum(point.Coord(k), -eye.Coord(k));
      for (const double part : difference.terms)
        off.product(-normal.Coord(k), part);
    }
  } else {
    for (int k = 1; k <= 3; ++k)
      off.product(-normal.Coord(k), direction.Coord(k));
  }
  if (kind == 2) {
    // cos(pi/2 + a) |N|, |N| as a high and a low part: the square root of
    // the high part of N.N, corrected to first order by what is left of it.
    Terms square;
    for (int k = 1; k <= 3; ++k)
      square.product(normal.Coord(k), normal.Coord(k));
    const auto [high, low] = square.parts();
    if (high > 0) {
      const double root = std::sqrt(high);
      Terms left;
      left.add(high);
      left.product(-root, root);
      left.add(low);
      const double cosAngle = std::cos(M_PI / 2. + angle);
      off.product(cosAngle, root);
      off.add(cosAngle * (left.total() / (2 * root)));
    }
  }
  const double away = std::abs(off.total());
  if (away == 0)
    return 0;
  return reading.rounding > 0 ? away / (m * reading.rounding) : RealLast();
}

struct Case {
  const char *name;
  Handle(Geom_Surface) surface;
  double u0, u1, v0, v1;
};

std::vector<Case> cases() {
  const gp_Ax3 frame(gp_Pnt(3, -2, 5), gp_Dir(0.3, 0.4, 0.866), gp_Dir(0.8, -0.6, 0));
  const gp_Ax3 far(gp_Pnt(1e4, -3e3, 2e3), gp_Dir(0, 0, 1), gp_Dir(1, 0, 0));
  NCollection_Array2<gp_Pnt> net(1, 4, 1, 4);
  for (int i = 1; i <= 4; ++i)
    for (int j = 1; j <= 4; ++j)
      net(i, j) = gp_Pnt(10 * i, 10 * j, 3 * std::sin(i * 1.3) * std::cos(j * 0.7));
  NCollection_Array1<double> knots(1, 2);
  knots(1) = 0;
  knots(2) = 1;
  NCollection_Array1<int> mults(1, 2);
  mults.Init(4);
  const Handle(Geom_Surface) spline = new Geom_BSplineSurface(net, knots, knots, mults, mults, 3, 3);
  const Handle(Geom_Curve) profile = GC_MakeSegment(gp_Pnt(12, 0, -5), gp_Pnt(18, 0, 9)).Value();
  return {
      {"plane", new Geom_Plane(frame), -10, 10, -10, 10},
      {"cylinder", new Geom_CylindricalSurface(frame, 7), 0, 2 * M_PI, -10, 10},
      {"cone", new Geom_ConicalSurface(frame, 0.4, 5), 0, 2 * M_PI, -10, 10},
      {"sphere", new Geom_SphericalSurface(frame, 9), 0, 2 * M_PI, -M_PI / 2, M_PI / 2},
      {"far sphere", new Geom_SphericalSurface(far, 9), 0, 2 * M_PI, -M_PI / 2, M_PI / 2},
      {"torus", new Geom_ToroidalSurface(frame, 30, 8), 0, 2 * M_PI, 0, 2 * M_PI},
      {"bspline", spline, 0, 1, 0, 1},
      {"bezier", new Geom_BezierSurface(net), 0, 1, 0, 1},
      {"revolution", new Geom_SurfaceOfRevolution(profile, gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1))), 0, 2 * M_PI,
       profile->FirstParameter(), profile->LastParameter()},
      {"extrusion", new Geom_SurfaceOfLinearExtrusion(profile, gp_Dir(0.2, 1, 0.1)), profile->FirstParameter(),
       profile->LastParameter(), -10, 10},
      {"offset", new Geom_OffsetSurface(new Geom_ToroidalSurface(frame, 30, 8), 1.5), 0, 2 * M_PI, 0, 2 * M_PI},
  };
}
} // namespace

int main() {
  const gp_Dir direction(0.36, -0.48, 0.8);
  const gp_Pnt eye(40, -70, 120);
  const double angle = 0.7;
  int failures = 0, compared = 0, uncovered = 0;
  double worst = 0;
  const char *where = "";
  for (const auto &c : cases()) {
    const TopoDS_Face face = BRepBuilderAPI_MakeFace(c.surface, c.u0, c.u1, c.v0, c.v1, Precision::Confusion());
    const Handle(Adaptor3d_Surface) adaptor = new BRepAdaptor_Surface(face);
    for (int kind = 0; kind < 3; ++kind) {
      Contap_SurfFunction occt;
      occt.Set(adaptor);
      ContourFunction ours(adaptor);
      if (kind == 0) {
        occt.Set(direction);
        ours.Set(direction);
      } else if (kind == 1) {
        occt.Set(eye);
        ours.Set(eye);
      } else {
        occt.Set(direction, angle);
        ours.Set(direction, angle);
      }
      math_Vector X(1, 2), F(1, 1);
      math_Matrix D(1, 1, 1, 2);
      // Points off the even fractions of the parameters, and at the ends.
      for (int i = 0; i <= 40; ++i)
        for (int j = 0; j <= 40; ++j) {
          const double u = c.u0 + (c.u1 - c.u0) * (i == 0 || i == 40 ? i / 40.0 : (i + 0.3819660112501051) / 41);
          const double v = c.v0 + (c.v1 - c.v0) * (j == 0 || j == 40 ? j / 40.0 : (j + 0.3819660112501051) / 41);
          X(1) = u;
          X(2) = v;
          occt.Value(X, F);
          const auto value = ours.value(u, v);
          occt.Values(X, F, D);
          const double f = F(1), du = D(1, 1), dv = D(1, 2);
          const auto values = ours.values(u, v);
          compared += 4;
          math_Vector G(1, 1);
          occt.Value(X, G);
          const bool equal = same(G(1), value.value) && same(f, values.value) && same(du, values.du) && same(dv, values.dv);
          if (!equal && ++failures <= 10)
            std::fprintf(stderr, "%s, kind %d, at (%.17g, %.17g): OCCT %.17g %.17g %.17g %.17g, here %.17g %.17g %.17g %.17g\n",
                         c.name, kind, u, v, G(1), f, du, dv, value.value, values.value, values.du, values.dv);
          // The bound against the exact value at OCCT's point and normal.
          for (const auto &reading : {value, values}) {
            const double share = overBound(ours, reading, adaptor, u, v, kind, direction, eye, angle);
            if (share > worst) {
              worst = share;
              where = c.name;
            }
            if (share > 1 && ++uncovered <= 10)
              std::fprintf(stderr, "%s, kind %d, at (%.17g, %.17g): rounding %.3g times the bound\n", c.name, kind, u, v,
                           share);
          }
        }
    }
  }
  std::printf("contour function: %d of %d values differ from OCCT's; rounding at most %.3g of the bound (%s), "
              "%d values beyond it\n",
              failures, compared, worst, where, uncovered);
  return failures == 0 && uncovered == 0 ? 0 : 1;
}
