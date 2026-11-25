// The grid of a face's parameters that the index of lines of sight keeps
// (sights.hxx): where it starts, where it is halved, and how far the image
// of the surface may stand beyond the image of each cell's triangles.
#include "sights.hxx"
#include "view.hxx"
#include <BRepTopAdaptor_TopolTool.hxx>
#include <NCollection_Array1.hxx>

namespace huak::space {
namespace {
// Where a parameter of the face's surface starts its grid: the ends of its
// C2 intervals, the pieces within which OCCT's intersector samples it, and
// as many parts in all as OCCT's topology tool takes samples of the surface
// that way, each interval at least one.
std::vector<double> parts(const BRepAdaptor_Surface &surface, bool alongU, int samples) {
  const int n = alongU ? surface.NbUIntervals(GeomAbs_C2) : surface.NbVIntervals(GeomAbs_C2);
  NCollection_Array1<double> ends(1, n + 1);
  if (alongU)
    surface.UIntervals(ends, GeomAbs_C2);
  else
    surface.VIntervals(ends, GeomAbs_C2);
  const double whole = ends(n + 1) - ends(1);
  std::vector<double> at;
  for (int k = 1; k <= n; ++k) {
    const double length = ends(k + 1) - ends(k);
    const long count = std::max(1L, std::lround(samples * length / whole));
    for (long part = 0; part < count; ++part)
      at.push_back(ends(k) + length * static_cast<double>(part) / static_cast<double>(count));
  }
  at.push_back(ends(n + 1));
  return at;
}

// Halves the parts between parameters that are marked.
void halve(std::vector<double> &at, const std::vector<bool> &split) {
  std::vector<double> finer{at.front()};
  for (size_t k = 0; k + 1 < at.size(); ++k) {
    if (split[k])
      finer.push_back((at[k] + at[k + 1]) / 2);
    finer.push_back(at[k + 1]);
  }
  at = std::move(finer);
}

// How far a point of the surface stands off the middle of points.
double off(const gp_Pnt &on, std::initializer_list<gp_Pnt> points) {
  gp_XYZ middle;
  for (const auto &p : points)
    middle += p.XYZ();
  return on.Distance(gp_Pnt(middle / static_cast<double>(points.size())));
}
} // namespace

// The surface is found at the middles of each cell's sides and diagonal and
// at its triangles' centroids. Starting from `parts`, a part is halved where
// a cell's sides along it stand off their chords by more than a sixteenth of
// the chord and than OCCT tells apart, and a cell's longer way where only
// its inside does, so that the surface turns by less than half a radian
// across a cell. How far the image of a cell's part of the surface may stand
// beyond its triangles' images is, as OCCT's polyhedron takes it, a fifth
// more than the most the samples' images are found to stand off them.
void Sights::Face::layOut(const HLRAlgo_Projector &projector) {
  const auto &s = *surface;
  BRepTopAdaptor_TopolTool tool(surface);
  us = parts(s, true, tool.NbSamplesU());
  vs = parts(s, false, tool.NbSamplesV());
  for (;;) {
    const size_t nu = us.size(), nv = vs.size();
    nodes.resize(nu * nv);
    for (size_t i = 0; i < nu; ++i)
      for (size_t j = 0; j < nv; ++j)
        nodes[at(i, j)] = s.Value(us[i], vs[j]);
    // How far the surface stands off the middle of each side along u, side
    // (i, j) at i * nv + j, and along v, side (i, j) at i * (nv - 1) + j.
    std::vector<double> offU((nu - 1) * nv), offV(nu * (nv - 1));
    for (size_t i = 0; i < nu; ++i)
      for (size_t j = 0; j < nv; ++j) {
        if (i + 1 < nu)
          offU[i * nv + j] = off(s.Value((us[i] + us[i + 1]) / 2, vs[j]), {nodes[at(i, j)], nodes[at(i + 1, j)]});
        if (j + 1 < nv)
          offV[i * (nv - 1) + j] = off(s.Value(us[i], (vs[j] + vs[j + 1]) / 2), {nodes[at(i, j)], nodes[at(i, j + 1)]});
      }
    std::vector<bool> splitU(nu - 1, false), splitV(nv - 1, false);
    bool any = false;
    for (size_t i = 0; i + 1 < nu; ++i)
      for (size_t j = 0; j + 1 < nv; ++j) {
        const double u0 = us[i], u1 = us[i + 1], v0 = vs[j], v1 = vs[j + 1];
        const gp_Pnt &a = nodes[at(i, j)], &b = nodes[at(i + 1, j)], &c = nodes[at(i + 1, j + 1)],
                     &d = nodes[at(i, j + 1)];
        const double bendU = std::max(offU[i * nv + j], offU[i * nv + j + 1]);
        const double bendV = std::max(offV[i * (nv - 1) + j], offV[(i + 1) * (nv - 1) + j]);
        const double away = std::max({bendU, bendV, off(s.Value((u0 + u1) / 2, (v0 + v1) / 2), {a, c}),
                                      off(s.Value((u0 + 2 * u1) / 3, (2 * v0 + v1) / 3), {a, b, c}),
                                      off(s.Value((2 * u0 + u1) / 3, (v0 + 2 * v1) / 3), {a, c, d})});
        const double alongU = std::max(a.Distance(b), d.Distance(c)), alongV = std::max(a.Distance(d), b.Distance(c));
        const auto bends = [](double off, double side) { return off > side / 16 && off > Precision::Confusion(); };
        bool halveU = bends(bendU, alongU), halveV = bends(bendV, alongV);
        if (!halveU && !halveV && bends(away, std::max(alongU, alongV)))
          (alongU >= alongV ? halveU : halveV) = true;
        if (nodes.size() >= (size_t{1} << 20))
          continue;
        if (halveU && u1 - u0 > Precision::PConfusion())
          any = splitU[i] = true;
        if (halveV && v1 - v0 > Precision::PConfusion())
          any = splitV[j] = true;
      }
    if (!any)
      break;
    halve(us, splitU);
    halve(vs, splitV);
  }
  const size_t nu = us.size(), nv = vs.size();
  images.resize(nu * nv);
  for (size_t k = 0; k < nodes.size(); ++k)
    projector.Project(nodes[k], images[k]);
  // In the image the samples stand off the images of the points of the
  // triangles they are compared with, which lie on the triangles' images:
  // as much as they stand off them in space, less how far that is along the
  // line of sight.
  const auto image = [&](const gp_Pnt &p) {
    gp_Pnt2d shown;
    projector.Project(p, shown);
    return shown;
  };
  const auto offImage = [&](double u, double v, std::initializer_list<gp_Pnt> points) {
    gp_XYZ middle;
    for (const auto &p : points)
      middle += p.XYZ();
    return image(s.Value(u, v)).Distance(image(gp_Pnt(middle / static_cast<double>(points.size()))));
  };
  reach.resize((nu - 1) * (nv - 1));
  for (size_t i = 0; i + 1 < nu; ++i)
    for (size_t j = 0; j + 1 < nv; ++j) {
      const double u0 = us[i], u1 = us[i + 1], v0 = vs[j], v1 = vs[j + 1];
      const gp_Pnt &a = nodes[at(i, j)], &b = nodes[at(i + 1, j)], &c = nodes[at(i + 1, j + 1)],
                   &d = nodes[at(i, j + 1)];
      reach[i * (nv - 1) + j] =
          1.2 * std::max({offImage((u0 + u1) / 2, v0, {a, b}), offImage((u0 + u1) / 2, v1, {d, c}),
                          offImage(u0, (v0 + v1) / 2, {a, d}), offImage(u1, (v0 + v1) / 2, {b, c}),
                          offImage((u0 + u1) / 2, (v0 + v1) / 2, {a, c}),
                          offImage((u0 + 2 * u1) / 3, (2 * v0 + v1) / 3, {a, b, c}),
                          offImage((2 * u0 + u1) / 3, (v0 + 2 * v1) / 3, {a, c, d})});
    }
  normals.resize(nu * nv);
  for (size_t i = 0; i < nu; ++i)
    for (size_t j = 0; j < nv; ++j) {
      gp_Dir normal;
      if (normalOf(geometry, false, gp_Pnt2d(us[i], vs[j]), normal))
        normals[at(i, j)] = normal;
    }
}
} // namespace huak::space
