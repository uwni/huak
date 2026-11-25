// The grid a contour is traced on: its nodes, the triangles of its cells,
// where the contour crosses their edges, and the paths it runs along through
// them.
#include "contours.hxx"

namespace huak::space::contour {
GridTrace::GridTrace(const TopoDS_Face &face, const ContourFunction &function,
                     const std::vector<double> &us, const std::vector<double> &vs,
                     const std::vector<TopoDS_Edge> &along)
    : face(face), function(function), us(us), vs(vs), along(along), built(face), onContour(function),
      surface(built.surface), singular(singularArcs(face)), classifier(face, Precision::PConfusion()) {
  const double u0 = us.front(), u1 = us.back(), v0 = vs.front(), v1 = vs.back();
  const auto index = [&](size_t i, size_t j) { return i * vs.size() + j; };
  // How far inside a singular side the function is taken: the step on the
  // face's parameters that GeomLib::NormEstim takes off a singular point to
  // orient the normal there (OCCT 8.0.1,
  // src/ModelingData/TKGeomBase/GeomLib/GeomLib.cxx, line 2601). OCCT takes
  // a point within what it tells apart of the singular point, in space, for
  // the point itself and gives it no normal, as by the pole of a surface of
  // revolution whose meridian ends on the axis; there the step must give the
  // normal length, and stay within half the grid's cell beside the side.
  constexpr double step = 1.0e-5;
  const auto inside = [&](int k, double side, double way, double cell) {
    if (step > cell / 2)
      throw std::runtime_error("a cell of the grid beside a singular point of a face is narrower than the step off it");
    const double across = k == 0 ? (v0 + v1) / 2 : (u0 + u1) / 2, at = side + way * step;
    if (!(k == 0 ? function.normalAt(at, across) : function.normalAt(across, at)))
      throw std::runtime_error("no normal is defined beside a singular point of a face");
    return step;
  };
  for (const auto &s : singular) {
    const gp_Pnt2d a = s.arc->Value(s.first), b = s.arc->Value(s.last);
    for (int k = 0; k < 2; ++k) {
      const auto &lines = k == 0 ? us : vs;
      const double low = lines.front(), high = lines.back(), at = a.Coord(k + 1), to = b.Coord(k + 1);
      if (std::abs(at - low) <= Precision::PConfusion() && std::abs(to - low) <= Precision::PConfusion())
        floor[k] = low + inside(k, low, 1, lines[1] - lines[0]);
      if (std::abs(at - high) <= Precision::PConfusion() && std::abs(to - high) <= Precision::PConfusion())
        ceiling[k] = high - inside(k, high, -1, lines.back() - lines[lines.size() - 2]);
    }
  }
  for (size_t i = 0; i < us.size(); ++i)
    for (size_t j = 0; j < vs.size(); ++j) {
      nodes.emplace_back(us[i], vs[j]);
      readings.push_back(valueAt(nodes.back()));
    }
  critical.assign(nodes.size(), false);
  for (size_t i = 0; i + 1 < us.size(); ++i)
    for (size_t j = 0; j + 1 < vs.size(); ++j) {
      const size_t corners[4] = {index(i, j), index(i + 1, j), index(i + 1, j + 1), index(i, j + 1)};
      if (past(corners[0]) == past(corners[2]) && past(corners[1]) == past(corners[3]) &&
          past(corners[0]) != past(corners[1])) {
        const double f00 = readings[corners[0]].value, f10 = readings[corners[1]].value,
                     f11 = readings[corners[2]].value, f01 = readings[corners[3]].value;
        const double across = f00 - f10 + f11 - f01;
        const gp_Pnt2d lo(us[i], vs[j]), hi(us[i + 1], vs[j + 1]);
        const gp_Pnt2d start(lo.X() + (hi.X() - lo.X()) * (f00 - f01) / across,
                             lo.Y() + (hi.Y() - lo.Y()) * (f00 - f10) / across);
        const auto found = criticalIn(lo, hi, start);
        nodes.push_back(found ? *found : start);
        readings.push_back(valueAt(nodes.back()));
        critical.push_back(found.has_value());
        for (int e = 0; e < 4; ++e)
          triangles.push_back({{corners[e], corners[(e + 1) % 4], nodes.size() - 1}, i, j});
      } else {
        triangles.push_back({{corners[0], corners[1], corners[2]}, i, j});
        triangles.push_back({{corners[0], corners[2], corners[3]}, i, j});
      }
    }
  for (const auto &[t, i, j] : triangles) {
    if (past(t[0]) == past(t[1]) && past(t[1]) == past(t[2]))
      continue;
    const size_t lone = past(t[0]) == past(t[1]) ? 2 : past(t[0]) == past(t[2]) ? 1 : 0;
    const size_t b0 = t[(lone + 1) % 3], b1 = t[(lone + 2) % 3];
    // A triangle whose base has both ends on the contour, and its middle
    // on the side of the lone vertex, holds no piece of the contour between
    // them: the contour only touches the triangle there.
    if (vanishes(readings[b0]) && vanishes(readings[b1])) {
      const auto middle = valueAt(gp_Pnt2d((nodes[b0].XY() + nodes[b1].XY()) / 2));
      if (!vanishes(middle) && past(middle) == past(t[lone]))
        continue;
    }
    const size_t c0 = crossing(t[lone], b0), c1 = crossing(t[lone], b1);
    links.push_back({{c0, c1}, t[lone], {b0, b1}, i, j});
    linksAt.resize(crossings.size());
    linksAt[c0].push_back(links.size() - 1);
    linksAt[c1].push_back(links.size() - 1);
  }
  linksAt.resize(crossings.size());
  used.assign(links.size(), false);
  for (size_t c = 0; c < crossings.size(); ++c)
    if (linksAt[c].size() == 1 && !used[linksAt[c][0]])
      follow(c);
  for (size_t c = 0; c < crossings.size(); ++c)
    if (std::any_of(linksAt[c].begin(), linksAt[c].end(), [&](size_t l) { return !used[l]; }))
      follow(c);
}

// Where the function's gradient vanishes in the cell from `lo` to `hi`, as
// Newton's method reaches it from `start`, the gradient's derivatives
// taken by its change over a millionth of the cell; none where the method
// leaves the cell or does not settle.
std::optional<gp_Pnt2d> GridTrace::criticalIn(const gp_Pnt2d &lo, const gp_Pnt2d &hi, const gp_Pnt2d &start) const {
  const double hu = 1e-6 * (hi.X() - lo.X()), hv = 1e-6 * (hi.Y() - lo.Y());
  gp_Pnt2d at = start;
  for (int step = 0; step < 32; ++step) {
    const gp_Vec2d g = gradientAt(at), gu = gradientAt(at.Translated(gp_Vec2d(hu, 0))),
                   gv = gradientAt(at.Translated(gp_Vec2d(0, hv)));
    const double a = (gu.X() - g.X()) / hu, b = (gv.X() - g.X()) / hv;
    const double c = (gu.Y() - g.Y()) / hu, d = (gv.Y() - g.Y()) / hv;
    const double det = a * d - b * c;
    if (!(std::abs(det) > 0))
      return std::nullopt;
    const gp_Vec2d move((b * g.Y() - d * g.X()) / det, (c * g.X() - a * g.Y()) / det);
    at.Translate(move);
    if (at.X() < lo.X() || at.X() > hi.X() || at.Y() < lo.Y() || at.Y() > hi.Y())
      return std::nullopt;
    if (move.Magnitude() <= 1e-3 * Precision::PConfusion())
      return at;
  }
  return std::nullopt;
}

// The contour point between a point past the contour, where the function
// reads `reading`, and one not: the past one where the function vanishes
// there as far as rounding tells, a root as Adams's criterion accepts one
// (OnContour); or the root of the function between them, as OCCT's root
// finder finds it where the function changes sign.
gp_Pnt2d GridTrace::rootBetween(const gp_Pnt2d &from, const ContourFunction::Reading &reading, const gp_Pnt2d &to) const {
  if (reading.value <= reading.rounding)
    return from;
  const std::function<double(double)> along = [&](double s) {
    return valueAt(gp_Pnt2d(from.X() + s * (to.X() - from.X()), from.Y() + s * (to.Y() - from.Y()))).value;
  };
  Scalar scalar(along);
  math_BracketedRoot root(scalar, 0, 1, 1e-3 * Precision::PConfusion() / std::max(1.0, from.Distance(to)));
  if (!root.IsDone())
    throw std::runtime_error("cannot find where a contour crosses a line on its face");
  const double s = root.Root();
  return gp_Pnt2d(from.X() + s * (to.X() - from.X()), from.Y() + s * (to.Y() - from.Y()));
}

size_t GridTrace::crossing(size_t a, size_t b) {
  const std::pair<size_t, size_t> key = std::minmax(a, b);
  if (const auto found = crossingOf.find(key); found != crossingOf.end())
    return found->second;
  if (!past(a))
    std::swap(a, b);
  const gp_Pnt2d uv = rootBetween(nodes[a], readings[a], nodes[b]);
  crossings.push_back({uv, surface->Value(uv.X(), uv.Y()), vanishes(readings[a]) ? std::optional<size_t>(a) : std::nullopt});
  crossingOf.emplace(key, crossings.size() - 1);
  return crossings.size() - 1;
}

// The contour point on the line from the lone vertex of a piece's
// triangle through `x`, a point on the chord of the traced contour: where
// the line first crosses the contour going out from the vertex, as far as
// `x` or the triangle's base, whichever is farther. A point where the
// function vanishes as far as rounding tells is on the contour, as Adams's
// criterion accepts a root (OnContour). Where the
// line meets the contour nowhere so far, the contour leaves the triangle
// across its base and comes back, which the nodes tell nothing of: the
// grid is halved there; but below what OCCT tells apart, the chord stands
// as near the contour as anything can.
gp_Pnt2d GridTrace::onLink(const Link &link, const gp_Pnt2d &x) {
  const gp_Pnt2d &a = nodes[link.lone], &b = nodes[link.base[0]], &c = nodes[link.base[1]];
  const bool side = past(link.lone);
  const gp_Vec2d toward(a, x), base(b, c);
  const double across = toward.Crossed(base);
  const double meets = across != 0 ? gp_Vec2d(a, b).Crossed(base) / across : 1;
  gp_Pnt2d inner = a;
  ContourFunction::Reading innerReading = readings[link.lone];
  for (const double s : {std::min(1.0, meets), std::max(1.0, meets)}) {
    if (!(s > 0))
      continue;
    const gp_Pnt2d outer = a.Translated(toward * s);
    const auto reading = valueAt(outer);
    if (vanishes(reading))
      return outer;
    if (past(reading) != side)
      return side ? rootBetween(inner, innerReading, outer) : rootBetween(outer, reading, inner);
    inner = outer;
    innerReading = reading;
  }
  if (us[link.i + 1] - us[link.i] > Precision::PConfusion() || vs[link.j + 1] - vs[link.j] > Precision::PConfusion())
    throw Unresolved{link.i, link.j};
  return x;
}

void GridTrace::follow(size_t start) {
  Path path{{start}, {}};
  for (size_t at = start;;) {
    const auto onward = std::find_if(linksAt[at].begin(), linksAt[at].end(), [&](size_t l) { return !used[l]; });
    if (onward == linksAt[at].end())
      break;
    used[*onward] = true;
    const Link &link = links[*onward];
    at = link.ends[0] == at ? link.ends[1] : link.ends[0];
    path.through.push_back(*onward);
    path.at.push_back(at);
  }
  paths.push_back(std::move(path));
}
} // namespace huak::space::contour
