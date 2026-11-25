#pragma once
// OCCT's contour function on a face's parameters, with the most the rounding
// of its computation may leave its value, and Newton's method onto the
// contour where it vanishes.
#include <Adaptor3d_Surface.hxx>
#include <Standard_Real.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Vec.hxx>
#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>

namespace huak::space::contour {
// OCCT's contour function on a face's parameters, with the most the
// rounding of its computation may leave its value from the function's:
// where the face's normal N is square to a direction d, to the line of sight
// from an eye E, or makes an angle with d. Contap_SurfFunction computes it
// as N.d / m, N.(P - E) / m or (N.d - cos(pi/2 + a) |N|) / m from the point
// P and the normal N that OCCT's Contap_SurfProps gives and the mean m of
// |N| over the points Contap_HContTool samples. It keeps N, P and m to
// itself, and the bound on the rounding depends on them; so the value is
// computed here from the same OCCT calls, operation for operation as
// Contap_SurfFunction computes it (tests/space_contour_function.cpp compares
// the two bit for bit), and contour_function.cpp derives the bound, which
// takes OCCT's point and normal as exact, as a floating-point filter takes
// its inputs.
class ContourFunction {
public:
  // As Contap_SurfFunction::Set(surface).
  explicit ContourFunction(const Handle(Adaptor3d_Surface) & surface);
  // As Contap_SurfFunction::Set, and named so, that what sets either up
  // takes either: square to a direction, to the line of sight from an eye,
  // or at the angle pi/2 + `angle` from a direction.
  void Set(const gp_Dir &direction);
  void Set(const gp_Pnt &eye);
  void Set(const gp_Dir &direction, double angle);

  // The function at a point of the face's parameters, the most the
  // rounding of its computation may leave it from the function's there, and
  // its gradient where asked.
  struct Reading {
    double value, rounding, du = 0, dv = 0;
  };
  // As Contap_SurfFunction::Value, and with the gradient as ::Values.
  Reading value(double u, double v) const;
  Reading values(double u, double v) const;
  // The mean m of |N| the function divides by, as Contap_SurfFunction
  // computes it.
  double meanLength() const { return mean; }
  // Whether OCCT's normal at a point, as Contap_SurfProps::Normale gives it
  // to the function, has length: where it has none, the function is nil and
  // tells nothing.
  bool normalAt(double u, double v) const;

private:
  enum class Kind { direction, eye, angle };
  // The most rounding may leave the value where OCCT's normal has
  // `length` at `point`.
  double roundingOf(double length, const gp_Pnt &point) const;

  Handle(Adaptor3d_Surface) surface;
  double mean = 1;
  Kind kind = Kind::direction;
  gp_Dir direction;
  gp_Pnt eye;
  double cosAngle = 0;
  // The part of the bound that stays the same from point to point: its
  // coefficients, with |d| where the direction d enters, over m.
  double scale = 0;
};

// The most a step on the face's parameters is stretched in space where the
// surface's first derivatives are `du` and `dv`: the larger singular value
// of the matrix whose columns they are.
inline double stretch(const gp_Vec &du, const gp_Vec &dv) {
  const double e = du.SquareMagnitude(), f = du.Dot(dv), g = dv.SquareMagnitude();
  return std::sqrt((e + g) / 2 + std::hypot((e - g) / 2, f));
}

// Newton's method along the gradient of the contour function moves a point
// onto the contour.
class OnContour {
public:
  explicit OnContour(const ContourFunction &function) : function(function) {}

  // A point on the contour, where the function vanishes as far as rounding
  // tells, and how far the contour may stand from it in the face's
  // parameters and the function still vanish there: the rounding over how
  // fast the function changes, as `blur` gives it.
  struct Reached {
    gp_Pnt2d uv;
    double blur;
  };
  // The contour point that Newton's method reaches from `uv`, moving no
  // farther than `limit`. None where the function's gradient vanishes, where
  // a step would go farther, or where eight steps do not reach it. It stops
  // where the value lies within its rounding, as Adams's criterion ends an
  // iteration where the computed value lies within the bound on its own
  // rounding (D. A. Adams, "A stopping criterion for polynomial root
  // finding", Comm. ACM 10 (1967) 655-658), or where the relative Newton
  // step falls below eps^(2/3) (J. E. Dennis Jr. and R. B. Schnabel,
  // Numerical Methods for Unconstrained Optimization and Nonlinear
  // Equations, SIAM 1996, section 7.2.1; OCCT math_FunctionSetRoot.hxx,
  // lines 67-79), returning Taubin's first-order blur from the larger of
  // the rounding bound and the residual.
  std::optional<Reached> operator()(const gp_Pnt2d &uv, double limit) const {
    constexpr double eps = std::numeric_limits<double>::epsilon();
    const double stepTol = std::cbrt(eps * eps);
    gp_Pnt2d at = uv;
    auto reading = function.values(at.X(), at.Y());
    for (int step = 0; step < 8; ++step) {
      const double slope = std::hypot(reading.du, reading.dv);
      if (!(slope > 0))
        return std::nullopt;
      if (std::abs(reading.value) <= reading.rounding)
        return Reached{at, reading.rounding / slope};
      const double s = reading.value / (slope * slope);
      const double du = s * reading.du, dv = s * reading.dv;
      at.SetCoord(at.X() - du, at.Y() - dv);
      if (at.Distance(uv) > limit)
        return std::nullopt;
      reading = function.values(at.X(), at.Y());
      if (std::abs(du) <= stepTol * std::max(1.0, std::abs(at.X())) &&
          std::abs(dv) <= stepTol * std::max(1.0, std::abs(at.Y()))) {
        const double newSlope = std::hypot(reading.du, reading.dv);
        if (!(newSlope > 0))
          return std::nullopt;
        return Reached{at, std::max(reading.rounding, std::abs(reading.value)) / newSlope};
      }
    }
    return std::nullopt;
  }

  // How far a point stands from the contour, in the face's parameters, as
  // its function there tells it to first order: its value over its slope.
  double away(const gp_Pnt2d &uv) const {
    const auto reading = function.values(uv.X(), uv.Y());
    const double slope = std::hypot(reading.du, reading.dv);
    return slope > 0 ? std::abs(reading.value) / slope : (reading.value == 0 ? 0 : RealLast());
  }

  // How far, in the face's parameters, the contour may stand from a point
  // on it and its function still vanish there as far as rounding tells: the
  // rounding over how fast the function changes there, the first-order
  // distance to where the function reaches its rounding, as a value over the
  // gradient's length approximates the distance to the curve where a
  // function vanishes (G. Taubin, "Estimation of planar curves, surfaces,
  // and nonplanar space curves defined by implicit equations", IEEE Trans.
  // Pattern Anal. Mach. Intell. 13 (1991) 1115-1138). Where it changes
  // slowly, as about where the contour crosses itself, that is far.
  double blur(const gp_Pnt2d &uv) const {
    const auto reading = function.values(uv.X(), uv.Y());
    const double slope = std::hypot(reading.du, reading.dv);
    return slope > 0 ? reading.rounding / slope : RealLast();
  }

  // Whether the function tells anything at a point: whether OCCT's normal
  // has length there.
  bool tells(const gp_Pnt2d &uv) const { return function.normalAt(uv.X(), uv.Y()); }

private:
  const ContourFunction &function;
};
} // namespace huak::space::contour
