// An image as a polyline, with how it lies about each chord, and where it turns back.
#include "arranging.hxx"

namespace huak::space {
// An image's curve in pieces: a line as one piece of two control points,
// a spline as OCCT cuts it at its knots.
void Arranging::cutIntoPieces(Image &image) {
  // A trimmed curve's basis curve has its parameter.
  Handle(Geom2d_Curve) curve = image.plane;
  while (const auto trimmed = Handle(Geom2d_TrimmedCurve)::DownCast(curve))
    curve = trimmed->BasisCurve();
  std::vector<Handle(Geom2d_BezierCurve)> pieces;
  if (const auto line = Handle(Geom2d_Line)::DownCast(curve); !line.IsNull()) {
    NCollection_Array1<gp_Pnt2d> ends(1, 2);
    ends(1) = line->Value(image.first);
    ends(2) = line->Value(image.last);
    pieces.push_back(new Geom2d_BezierCurve(ends));
    image.knots = {image.first, image.last};
  } else {
    const auto spline = Handle(Geom2d_BSplineCurve)::DownCast(curve);
    if (spline.IsNull())
      throw std::runtime_error(std::string("an image is neither a line nor a spline: ") + curve->DynamicType()->Name());
    Geom2dConvert_BSplineCurveToBezierCurve cut(spline, image.first, image.last, Precision::PConfusion());
    NCollection_Array1<double> knots(1, cut.NbArcs() + 1);
    cut.Knots(knots);
    for (int n = 1; n <= cut.NbArcs(); ++n)
      pieces.push_back(cut.Arc(n));
    for (int n = 1; n <= knots.Length(); ++n)
      image.knots.push_back(knots(n));
    // OCCT may take a knot within its tolerance for an end.
    image.knots.front() = image.first;
    image.knots.back() = image.last;
  }
  // The coefficients as a Bézier curve takes them to cut itself to a part
  // of its range.
  for (const auto &piece : pieces) {
    Bezier bezier{piece, std::vector<gp_Pnt2d>(static_cast<size_t>(piece->NbPoles())), {}};
    NCollection_Array1<gp_Pnt2d> coefficients(bezier.coefficients.front(), 1, piece->NbPoles());
    if (piece->IsRational()) {
      bezier.weights.resize(bezier.coefficients.size());
      NCollection_Array1<double> weights(bezier.weights.front(), 1, piece->NbPoles());
      BSplCLib::PolesCoefficients(piece->Poles(), piece->Weights(), coefficients, &weights);
    } else {
      BSplCLib::PolesCoefficients(piece->Poles(), coefficients);
    }
    image.beziers.push_back(std::move(bezier));
  }
}

// How an image lies about the chord from `from` to `to` over [a, b], as
// the control points of its pieces there tell: within the most any
// stands from the chord, and heading among the steps between them in
// order. A step of none heads nowhere.
Arranging::Hull Arranging::hullOf(size_t k, double a, double b, const gp_Pnt2d &from, const gp_Pnt2d &to) const {
  Hull hull;
  const gp_Vec2d chord(from, to);
  hull.headed = chord.SquareMagnitude() > 0;
  bool any = false;
  hullOver(k, a, b, [&](const NCollection_Array1<gp_Pnt2d> &poles) {
    for (int j = poles.Lower(); j <= poles.Upper(); ++j) {
      hull.off = std::max(hull.off, apart(poles(j), from, to));
      if (j == poles.Lower() || !hull.headed)
        continue;
      const gp_Vec2d step(poles(j - 1), poles(j));
      if (step.X() == 0 && step.Y() == 0)
        continue;
      const double angle = std::atan2(chord.Crossed(step), chord.Dot(step));
      if (!(std::abs(angle) < M_PI / 2)) {
        hull.headed = false;
        continue;
      }
      hull.low = any ? std::min(hull.low, angle) : angle;
      hull.high = any ? std::max(hull.high, angle) : angle;
      any = true;
    }
  });
  hull.headed = hull.headed && any;
  return hull;
}

// An image's polyline: each of its pieces halved until over each part
// the image heads within `turning` of one way, as the control points
// tell, or goes no farther than a thousandth of what OCCT tells apart, or
// spans no more of the range than it tells apart; then each segment as
// many of those parts in a row as the image heads within `turning` of
// one way over, however the spline's knots cut it; and how it lies about
// each segment.
//
// Over a segment the image turns little, unless it turns back there: it
// stands still and runs back the way it came, or turns within less than
// OCCT tells points apart. Then the chords before and after point
// opposite ways, and the image turns where it goes farthest the way it
// came, as OCCT's minimizer finds between the points around: that point
// is one of the polyline's.
void Arranging::outline(size_t k) {
  auto &image = images[k];
  // A part of a piece: its range, and the least and the most way it
  // heads, as angles, where it heads within `turning` of one way.
  struct Heading {
    double a, b;
    bool headed;
    double low, high;
  };
  std::vector<Heading> parts;
  const std::function<void(double, double)> refine = [&](double a, double b) {
    const gp_Pnt2d from = at(k, a), to = at(k, b);
    const Hull hull = hullOf(k, a, b, from, to);
    if (hull.headed && hull.high - hull.low <= turning) {
      const double way = std::atan2(to.Y() - from.Y(), to.X() - from.X());
      parts.push_back({a, b, true, way + hull.low, way + hull.high});
      return;
    }
    if (b - a <= Precision::PConfusion() || from.Distance(to) + 2 * hull.off <= 1e-3 * Precision::Confusion()) {
      parts.push_back({a, b, false, 0, 0});
      return;
    }
    const double middle = (a + b) / 2;
    refine(a, middle);
    refine(middle, b);
  };
  for (size_t n = 0; n < image.beziers.size(); ++n)
    if (image.knots[n + 1] > image.knots[n])
      refine(image.knots[n], image.knots[n + 1]);
  // Over parts in a row the image heads among the ways each does; the
  // angles of a part's are taken within a half turn of the first's.
  std::vector<double> parameters{image.first};
  for (size_t n = 0; n < parts.size();) {
    size_t m = n + 1;
    if (parts[n].headed) {
      const double reference = parts[n].low;
      double low = parts[n].low, high = parts[n].high;
      for (; m < parts.size() && parts[m].headed; ++m) {
        const double shift = std::remainder(parts[m].low - reference, 2 * M_PI) - (parts[m].low - reference);
        const double least = std::min(low, parts[m].low + shift), most = std::max(high, parts[m].high + shift);
        if (most - least > turning)
          break;
        low = least;
        high = most;
      }
    }
    parameters.push_back(parts[m - 1].b);
    n = m;
  }
  gp_Vec2d came;
  bool moving = false;
  for (size_t n = 0; n < parameters.size(); ++n) {
    const double t = parameters[n];
    const gp_Pnt2d p = image.adaptor->Value(t);
    if (image.points.empty()) {
      image.at.push_back(t);
      image.points.push_back(p);
      continue;
    }
    gp_Vec2d chord(image.points.back(), p);
    // Standing where the last point does, the image has gone nowhere yet.
    if (chord.Magnitude() <= Precision::Confusion() && n + 1 < parameters.size())
      continue;
    if (moving && chord.Dot(came) < 0) {
      const bool between = image.at.size() >= 2;
      const double lo = between ? image.at[image.at.size() - 2] : image.at.back();
      const gp_Dir2d way(came);
      const std::function<double(double)> behind = [&](double s) {
        return -gp_Vec2d(image.points.back(), image.adaptor->Value(s)).Dot(gp_Vec2d(way));
      };
      Scalar function(behind);
      math_BrentMinimum farthest(Precision::PConfusion());
      farthest.Perform(function, lo, image.at.back(), t);
      if (!farthest.IsDone())
        throw std::runtime_error("cannot find where an image turns back");
      const double turn = std::clamp(farthest.Location(), lo, t);
      // The turn is a point of the polyline: after the last, or in its
      // place where the image had turned before it.
      if (turn > image.at.back() + Precision::PConfusion()) {
        image.at.push_back(turn);
        image.points.push_back(image.adaptor->Value(turn));
      } else if (between && turn < image.at.back() - Precision::PConfusion()) {
        image.at.back() = turn;
        image.points.back() = image.adaptor->Value(turn);
      }
      if (turn > image.first + Precision::PConfusion() && turn < image.last - Precision::PConfusion())
        image.turns.push_back(turn);
      chord = gp_Vec2d(image.points.back(), p);
    }
    if (chord.Magnitude() > Precision::Confusion()) {
      came = chord;
      moving = true;
    }
    if (t > image.at.back() + Precision::PConfusion()) {
      image.at.push_back(t);
      image.points.push_back(p);
    }
  }
  if (image.at.size() < 2)
    throw std::runtime_error("an image has no extent");
  for (size_t n = 0; n + 1 < image.at.size(); ++n) {
    const Hull hull = hullOf(k, image.at[n], image.at[n + 1], image.points[n], image.points[n + 1]);
    image.nodes.push_back({{image.at[n], image.at[n + 1], image.points[n], image.points[n + 1], hull}});
    image.offs.push_back(hull.off);
    image.off = std::max(image.off, hull.off);
  }
  for (const auto &p : image.points)
    image.box.Add(p.XY());
  image.box.Enlarge(image.off + image.blur + Precision::Confusion());
}
} // namespace huak::space
