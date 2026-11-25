// OCCT's contour function, computed as Contap_SurfFunction computes it, with
// the most the rounding of that computation may leave its value from the
// function's.
#include "contour_function.hxx"
#include <Contap_HContTool.hxx>
#include <Contap_SurfProps.hxx>
#include <limits>

namespace huak::space::contour {
namespace {
// The unit roundoff u, the relative error of one rounding.
constexpr double unit = std::numeric_limits<double>::epsilon() / 2;
// A bound's coefficient (a + b u) u, written as Shewchuk writes his so that
// it is a double and computed without rounding: a + b u is one for the a
// and b below, b being a multiple of the spacing of the doubles about a, in
// units of u.
constexpr double coefficient(double a, double b) { return (a + b * unit) * unit; }

// How far rounding may leave the value, bounded as a floating-point filter
// bounds it (S. Fortune and C. J. Van Wyk, "Efficient exact arithmetic for
// computational geometry", Proc. 9th Annual Symposium on Computational
// Geometry, ACM 1993, 163-172; J. R. Shewchuk, "Adaptive precision
// floating-point arithmetic and fast robust geometric predicates", Discrete
// Comput. Geom. 18 (1997) 305-363, section 4.2): the inputs are exact and
// the bound covers the arithmetic done on them here. The inputs are the
// point P and the normal N that OCCT's Contap_SurfProps gives, the
// direction d or the eye E the function is set with, and its constants, the
// mean m of |N| and cos(pi/2 + a), which Contap_SurfFunction computes as
// this does and which define the function it solves.
//
// Each operation here leaves its result within a relative u of the exact
// one, and gamma_k = k u / (1 - k u) bounds k such roundings in a row (N. J.
// Higham, Accuracy and Stability of Numerical Algorithms, 2nd ed., SIAM
// 2002: the standard model of section 2.2, Lemma 3.1). gp_XYZ::Dot sums the
// three products in a row, so each term of a dot product goes through at
// most three roundings (section 3.1; a fused multiply-add only removes
// one); the line of sight P - E adds one, the division by m another, and at
// an angle the difference one more. The computed length |N|, the square
// root of such a sum of squares, lies within a factor (1 + u)^(5/2) of it
// either way, and its product with cos(pi/2 + a), the difference and the
// division take it within (1 + u)^(11/2), which gamma_6 bounds. So with
// n = |N|, W = |P - E| and c = |cos(pi/2 + a)| the value lies within
//   N.d / m:              gamma_4 n |d| / m
//   N.(P - E) / m:        gamma_5 n W / m
//   (N.d - c |N|) / m:    (gamma_5 |d| + gamma_6 c) n / m
// of the function's.
//
// Shewchuk's bound for his first approximation in ORIENT2D shows how such
// a bound is computed: from computed values, its coefficient multiplied by
// 1 + u for each operation that computes it, as a computed result is at
// least the exact one over 1 + u (Higham, section 2.2, (2.5)), and rounded
// up to the next double. The computed n, W and |d| are at least the exact
// ones over (1 + u)^(5/2), (1 + u)^(7/2) for W with its difference; `Set`
// and `roundingOf` compute the bound in three operations, four at an angle;
// so the coefficients are, rounded up,
//   gamma_4 (1 + u)^8 <= (4 + 56 u) u      for n |d|, along a direction
//   gamma_5 (1 + u)^9 <= (5 + 72 u) u      for n W from an eye, n |d| at an angle
//   gamma_6 (1 + u)^(13/2) <= (6 + 80 u) u for n c at an angle
// As Shewchuk's, the bound holds where nothing underflows or overflows.
constexpr double fourRoundings = coefficient(4, 56);
constexpr double fiveRoundings = coefficient(5, 72);
constexpr double sixRoundings = coefficient(6, 80);
} // namespace

ContourFunction::ContourFunction(const Handle(Adaptor3d_Surface) & surface) : surface(surface) {
  // As Contap_SurfFunction::Set(surface), sample point by sample point.
  const int count = Contap_HContTool::NbSamplePoints(surface);
  if (count > 0) {
    gp_Pnt point;
    gp_Vec normal;
    mean = 0.;
    for (int i = 1; i <= count; i++) {
      double u, v;
      Contap_HContTool::SamplePoint(surface, i, u, v);
      Contap_SurfProps::Normale(surface, u, v, point, normal);
      mean = mean + normal.Magnitude();
    }
    mean = mean / ((double)count);
  }
}

void ContourFunction::Set(const gp_Dir &toward) {
  kind = Kind::direction;
  direction = toward;
  scale = fourRoundings * toward.XYZ().Modulus() / mean;
}

void ContourFunction::Set(const gp_Pnt &from) {
  kind = Kind::eye;
  eye = from;
  scale = fiveRoundings / mean;
}

void ContourFunction::Set(const gp_Dir &toward, double angle) {
  kind = Kind::angle;
  direction = toward;
  cosAngle = std::cos(M_PI / 2. + angle);
  scale = (fiveRoundings * toward.XYZ().Modulus() + sixRoundings * std::abs(cosAngle)) / mean;
}

double ContourFunction::roundingOf(double length, const gp_Pnt &point) const {
  if (kind == Kind::eye)
    return scale * length * gp_Vec(eye, point).Magnitude();
  return scale * length;
}

bool ContourFunction::normalAt(double u, double v) const {
  gp_Pnt point;
  gp_Vec normal;
  Contap_SurfProps::Normale(surface, u, v, point, normal);
  return normal.SquareMagnitude() > 0;
}

ContourFunction::Reading ContourFunction::value(double u, double v) const {
  gp_Pnt point;
  gp_Vec normal;
  Contap_SurfProps::Normale(surface, u, v, point, normal);
  const double length = normal.Magnitude();
  double f = 0;
  switch (kind) {
  case Kind::direction:
    f = (normal.Dot(direction)) / mean;
    break;
  case Kind::eye:
    f = (normal.Dot(gp_Vec(eye, point))) / mean;
    break;
  case Kind::angle:
    f = (normal.Dot(direction) - cosAngle * length) / mean;
    break;
  }
  return {f, roundingOf(length, point)};
}

ContourFunction::Reading ContourFunction::values(double u, double v) const {
  gp_Pnt point;
  gp_Vec normal, du, dv;
  Contap_SurfProps::NormAndDn(surface, u, v, point, normal, du, dv);
  const double length = normal.Magnitude();
  Reading reading{0, roundingOf(length, point)};
  switch (kind) {
  case Kind::direction:
    reading.value = (normal.Dot(direction)) / mean;
    reading.du = (du.Dot(direction)) / mean;
    reading.dv = (dv.Dot(direction)) / mean;
    break;
  case Kind::eye: {
    const gp_Vec sight(eye, point);
    reading.value = (normal.Dot(sight)) / mean;
    reading.du = (du.Dot(sight)) / mean;
    reading.dv = (dv.Dot(sight)) / mean;
    break;
  }
  case Kind::angle:
    reading.value = (normal.Dot(direction) - cosAngle * length) / mean;
    // Where OCCT's normal has no length its direction, and so the slope of
    // the angle it makes, is not defined: the reading tells nothing, and has
    // no slope. Contap_SurfFunction::Values fails there.
    if (length > 0) {
      normal.Normalize();
      reading.du = (du.Dot(direction) - cosAngle * du.Dot(normal)) / mean;
      reading.dv = (dv.Dot(direction) - cosAngle * dv.Dot(normal)) / mean;
    }
    break;
  }
  return reading;
}
} // namespace huak::space::contour
