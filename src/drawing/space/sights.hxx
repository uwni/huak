#pragma once
// Where the lines of sight of a view meet the faces of the model's shapes.
// A line of sight is one point of the image plane, and a face can be met
// only where its image covers that point. The index keeps the image of each
// face in OCCT's BVH: a face that OCCT meets in closed form, a plane, a
// quadric or a torus, by its box, asking OCCT's line and face intersector
// only where the box holds the point; any other face by the cells of a grid
// of its parameters (sights_grid.cpp), each cell's image widened by how far
// the surface may stand off the cell's two triangles. Each triangle whose
// image stands within that of the point seeds OCCT's curve and surface
// solver at the point of the image nearest it; near the outline, where the
// line crosses the surface twice close together, the solver also starts on
// either side of it and where the surface's osculating quadric puts the
// second crossing. OCCT's classifier keeps the roots in the face as OCCT's
// intersector does. That intersector seeds its solver from every edge of a
// coarse polyhedron that passes near the line, a hundred seeds and more
// where a line crosses a free-form face at a slant.
#include "space.hxx"
#include <BRepAdaptor_Surface.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BVH_BoxSet.hxx>
#include <Geom_Surface.hxx>
#include <IntCurvesFace_Intersector.hxx>
#include <gp_Lin.hxx>
#include <optional>

namespace huak::space {
// Where a line of sight meets a face: the root shape and the face's index,
// the point on the line, and its parameters on the face and on the line.
struct Sight {
  size_t source, face;
  gp_Pnt point;
  double u, v, w;
};

class Sights {
public:
  Sights(const HuakModel &model, const HLRAlgo_Projector &projector);
  ~Sights();
  // Where the line of sight through `at` meets the faces of the shapes with
  // faces, shape by shape, each shape's in order along the line.
  void meet(const gp_Pnt2d &at, std::vector<Sight> &out);
  // Where it meets face `face` of shape `source`, in order along the line.
  void meet(size_t source, size_t face, const gp_Pnt2d &at, std::vector<Sight> &out);

  struct Face {
    size_t source, index;
    TopoDS_Face face;
    // The face's surface over the face's bounds, as OCCT's intersector
    // loads it, the same surface as the face places it, and the face's box.
    Handle(BRepAdaptor_Surface) surface;
    Handle(Geom_Surface) geometry;
    Bnd_Box box;
    // OCCT's intersector, for a face it meets in closed form.
    Handle(IntCurvesFace_Intersector) closed;
    // Otherwise the grid: its parameters; its nodes in space and in the
    // image, node (i, j) at i * vs.size() + j, and the normals there, where
    // the surface has one; and for each cell, cell (i, j) at
    // i * (vs.size() - 1) + j, how far beyond its triangles the image of its
    // part of the surface may stand.
    std::vector<double> us, vs;
    std::vector<gp_Pnt> nodes;
    std::vector<gp_Pnt2d> images;
    std::vector<std::optional<gp_Dir>> normals;
    std::vector<double> reach;
    // OCCT's classifiers of the face's parameters, as its intersector keeps
    // roots: at the least of the tolerances of the face and its edges, and
    // at the greatest, made when first asked; and the greatest in space.
    std::unique_ptr<BRepTopAdaptor_FClass2d> least, most;
    double leastTolerance = 0, mostTolerance = 0, spaceTolerance = 0;

    size_t at(size_t i, size_t j) const { return i * vs.size() + j; }
    // Lays out the grid as the projector sees it (sights_grid.cpp).
    void layOut(const HLRAlgo_Projector &projector);
  };
  // A box of the index: a cell of a face's grid, or a face that OCCT meets
  // in closed form, whose cell is -1.
  struct Entry {
    int face, cell;
  };

private:
  const HLRAlgo_Projector &projector;
  // The faces of the shapes with faces, shape by shape; where each shape's
  // begin, and where they end.
  std::vector<std::unique_ptr<Face>> faces;
  std::vector<size_t> first;
  BVH_BoxSet<double, 2, Entry> boxes;
  std::vector<Entry> held;

  // The entries whose boxes hold `at`, of face `only` alone unless it is
  // negative, by face and cell.
  void collect(const gp_Pnt2d &at, int only);
  // Appends where the line meets a face, from the entries of the face that
  // hold its point.
  void meetFace(Face &face, const gp_Lin &line, const gp_Pnt2d &at, const Entry *from, const Entry *to,
                std::vector<Sight> &out);
};
} // namespace huak::space
