#ifndef HUAK_SPACE_PROJECTION_H
#define HUAK_SPACE_PROJECTION_H
#include <stddef.h>
#include <stdint.h>

enum HuakModelKind {
  HUAK_SEGMENT,
  HUAK_CUBIC,
  HUAK_TORUS,
  HUAK_SURFACE_CURVE,
  HUAK_FACE,
  HUAK_EXTRUDE,
  HUAK_REVOLVE,
  HUAK_SPHERE,
  HUAK_CYLINDER,
  HUAK_CONE,
  HUAK_CIRCLE,
  HUAK_ELLIPSE,
  HUAK_ARC,
  HUAK_PROFILE,
  HUAK_POLYLINE,
  HUAK_POLYGON,
  HUAK_JOINED,
  HUAK_REVERSE,
  HUAK_CLOSED,
  HUAK_TRANSFORMED,
  HUAK_SWEEP,
  HUAK_LOFT,
  HUAK_SOLID_LOFT,
  HUAK_FUSE,
  HUAK_COMMON,
  HUAK_CUT
};
enum HuakProjectedKind {
  HUAK_EDGE,
  HUAK_OUTLINE,
  HUAK_SMOOTH,
  HUAK_SEAM,
  HUAK_CURVE,
  HUAK_INTERSECTION
};
enum HuakPathOp { HUAK_MOVE, HUAK_LINE, HUAK_BEZIER, HUAK_CLOSE };
typedef struct {
  double x, y;
} HuakXY;
typedef struct {
  double xyz[3];
} HuakXYZ;
typedef struct {
  int op;
  HuakXY p[3];
} HuakPathCommand;
typedef struct HuakModelShape {
  int kind;
  double args[12];
  double origin[3], u[3], v[3];
  const size_t *inputs;
  size_t input_count;
  const HuakXYZ *points;
  int face;
  const HuakPathCommand *profile;
  size_t count;
} HuakModelShape;
typedef struct {
  size_t source, start, count, covering;
  int kind;
  ptrdiff_t other_source;
} HuakProjectedLine;
typedef struct {
  size_t source, face, start, count, covering;
} HuakProjectedFace;
typedef struct {
  const HuakPathCommand *commands;
  const HuakProjectedLine *lines;
  size_t count;
  const HuakProjectedFace *faces;
  size_t face_count;
  void *owner;
} HuakLinework;
#ifdef __cplusplus
extern "C" {
#endif
/* All input is borrowed for the call. On success release the output once.
   Focus zero selects orthographic projection. Coordinates are in points. */
int huak_space_project(const HuakModelShape *, size_t node_count,
                       const size_t *roots, size_t count, double azimuth,
                       double elevation, double focus, double tolerance,
                       int include_faces, HuakLinework *, char *error,
                       size_t capacity);
void huak_space_release(HuakLinework *);
#ifdef __cplusplus
}
#endif
#endif
