#pragma once
#include "result.hxx"
#include <TopTools_ListOfShape.hxx>
#include <TopoDS_Face.hxx>
namespace huak::space {
struct FaceLight {
  bool planar = false;
  TopTools_IndexedMapOfShape lit_cells;
  size_t start = 0, count = 0;
};

class Lighting {
public:
  Lighting(const HuakLight &, const Surfaces &, const HLRAlgo_Projector &,
           const gp_Dir &, double tolerance, TopTools_ListOfShape &boundaries);
  struct Sample {
    double diffuse;
    bool gleam;
  };
  Sample classify(const Hit &, const TopoDS_Face &source,
                  const TopoDS_Face &cell);
  void fitSpots(Result &);
  const FaceLight &face(size_t source, int index) const {
    return faces_[source][index];
  }

private:
  std::vector<std::vector<FaceLight>> faces_;
  const HuakLight &light_;
  gp_Dir sun_, eye_;
  std::optional<gp_Dir> half;
  double cutoff;
};
} // namespace huak::space
