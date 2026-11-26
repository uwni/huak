// The grid of a face's parameters that the index of lines of sight keeps
// (sights.hxx): where it starts, where it is halved, and how far the image
// of the surface may stand beyond the image of each cell's triangles.
#include "sights.hxx"
#include "view.hxx"
#include <BRepTopAdaptor_TopolTool.hxx>
#include <CSLib.hxx>
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
  const bool reversed = face.Orientation() == TopAbs_REVERSED;
  const auto image = [&](const gp_Pnt &p) {
    gp_Pnt2d shown;
    projector.Project(p, shown);
    return shown;
  };
  BRepTopAdaptor_TopolTool tool(surface);
  us = parts(s, true, tool.NbSamplesU());
  vs = parts(s, false, tool.NbSamplesV());
  for (;;) {
    const size_t nu = us.size(), nv = vs.size();
    nodes.resize(nu * nv);
    normals.assign(nu * nv, std::nullopt);
    for (size_t i = 0; i < nu; ++i)
      for (size_t j = 0; j < nv; ++j) {
        const size_t k = at(i, j);
        gp_Vec du, dv;
        s.D1(us[i], vs[j], nodes[k], du, dv);
        CSLib_NormalStatus status;
        gp_Dir normal;
        CSLib::Normal(du, dv, Precision::Confusion(), status, normal);
        if (status == CSLib_Defined) {
          if (reversed)
            normal.Reverse();
          normals[k] = normal;
        }
      }
    // How far the surface stands off the middle of each side along u, side
    // (i, j) at i * nv + j, and along v, side (i, j) at i * (nv - 1) + j,
    // both in space and in the image.
    std::vector<double> offU((nu - 1) * nv), offV(nu * (nv - 1));
    std::vector<double> imgU((nu - 1) * nv), imgV(nu * (nv - 1));
    for (size_t i = 0; i < nu; ++i)
      for (size_t j = 0; j < nv; ++j) {
        if (i + 1 < nu) {
          const gp_Pnt on = s.Value((us[i] + us[i + 1]) / 2, vs[j]);
          const gp_Pnt mid((nodes[at(i, j)].XYZ() + nodes[at(i + 1, j)].XYZ()) / 2);
          offU[i * nv + j] = on.Distance(mid);
          imgU[i * nv + j] = image(on).Distance(image(mid));
        }
        if (j + 1 < nv) {
          const gp_Pnt on = s.Value(us[i], (vs[j] + vs[j + 1]) / 2);
          const gp_Pnt mid((nodes[at(i, j)].XYZ() + nodes[at(i, j + 1)].XYZ()) / 2);
          offV[i * (nv - 1) + j] = on.Distance(mid);
          imgV[i * (nv - 1) + j] = image(on).Distance(image(mid));
        }
      }
    std::vector<bool> splitU(nu - 1, false), splitV(nv - 1, false);
    reach.resize((nu - 1) * (nv - 1));
    bool any = false;
    for (size_t i = 0; i + 1 < nu; ++i)
      for (size_t j = 0; j + 1 < nv; ++j) {
        const double u0 = us[i], u1 = us[i + 1], v0 = vs[j], v1 = vs[j + 1];
        const gp_Pnt &a = nodes[at(i, j)], &b = nodes[at(i + 1, j)], &c = nodes[at(i + 1, j + 1)],
                     &d = nodes[at(i, j + 1)];
        const double bendU = std::max(offU[i * nv + j], offU[i * nv + j + 1]);
        const double bendV = std::max(offV[i * (nv - 1) + j], offV[(i + 1) * (nv - 1) + j]);
        const gp_Pnt diagOn = s.Value((u0 + u1) / 2, (v0 + v1) / 2);
        const gp_Pnt diagMid((a.XYZ() + c.XYZ()) / 2);
        const gp_Pnt tri1On = s.Value((u0 + 2 * u1) / 3, (2 * v0 + v1) / 3);
        const gp_Pnt tri1Mid((a.XYZ() + b.XYZ() + c.XYZ()) / 3);
        const gp_Pnt tri2On = s.Value((2 * u0 + u1) / 3, (v0 + 2 * v1) / 3);
        const gp_Pnt tri2Mid((a.XYZ() + c.XYZ() + d.XYZ()) / 3);
        const double away = std::max({bendU, bendV, diagOn.Distance(diagMid),
                                      tri1On.Distance(tri1Mid), tri2On.Distance(tri2Mid)});
        const double alongU = std::max(a.Distance(b), d.Distance(c)), alongV = std::max(a.Distance(d), b.Distance(c));
        const auto bends = [](double off, double side) { return off > side / 16 && off > Precision::Confusion(); };
        bool halveU = bends(bendU, alongU), halveV = bends(bendV, alongV);
        if (!halveU && !halveV && bends(away, std::max(alongU, alongV)))
          (alongU >= alongV ? halveU : halveV) = true;
        if (nodes.size() < (size_t{1} << 20)) {
          if (halveU && u1 - u0 > Precision::PConfusion())
            any = splitU[i] = true;
          if (halveV && v1 - v0 > Precision::PConfusion())
            any = splitV[j] = true;
        }
        // In the image the samples stand off the images of the points of the
        // triangles they are compared with, which lie on the triangles' images:
        // as much as they stand off them in space, less how far that is along
        // the line of sight.
        if (!any) {
          reach[i * (nv - 1) + j] =
              1.2 * std::max({imgU[i * nv + j], imgU[i * nv + j + 1],
                              imgV[i * (nv - 1) + j], imgV[(i + 1) * (nv - 1) + j],
                              image(diagOn).Distance(image(diagMid)),
                              image(tri1On).Distance(image(tri1Mid)),
                              image(tri2On).Distance(image(tri2Mid))});
        }
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
  for (size_t i = 0; i < nu; ++i)
    for (size_t j = 0; j < nv; ++j)
      if (!normals[at(i, j)]) {
        gp_Dir normal;
        if (normalOf(geometry, face, gp_Pnt2d(us[i], vs[j]), normal))
          normals[at(i, j)] = normal;
      }
}
} // namespace huak::space
