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
  HUAK_CUT,
  /* A surface through a grid of points: args[0] rows of args[1] points,
     row after row in `points`. */
  HUAK_GRID
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

/* Built shapes. Queries name a face by the index of its root shape and its
   index among that shape's faces. */
typedef struct HuakModel HuakModel;
/* A root shape: how many faces it has, and its bounding box with its
   tolerance, or `empty` when it has no geometry. */
typedef struct {
  size_t faces;
  double box[6]; /* x0, y0, z0, x1, y1, z1 */
  int empty;
} HuakShape;
enum HuakSurfaceKind {
  HUAK_PLANAR,
  HUAK_CYLINDRICAL,
  HUAK_CONICAL,
  HUAK_SPHERICAL,
  HUAK_TOROIDAL,
  HUAK_FREEFORM
};
/* A face's surface: its kind, the face's parameter bounds, the period of
   each parameter or zero, a cone's semi-angle and the v of its apex, where
   its rulings meet, and a cylinder's frame, in which u is the angle from
   axis_x toward axis_y. */
typedef struct {
  int kind;
  double u0, u1, v0, v1;
  double u_period, v_period;
  double semi_angle;
  double apex_v;
  double axis_x[3], axis_y[3];
} HuakFace;
typedef struct {
  double u, v;
} HuakUV;
/* The derivatives along u and v of a face's unit normal, as oriented in its
   shape; `defined` is zero where the surface is singular. */
typedef struct {
  double du[3], dv[3];
  int defined;
} HuakNormalTurn;
/* A straight segment in a face's parameters. */
typedef struct {
  HuakUV from, to;
} HuakSegment;

/* A camera on a model, and the space curves, planar images and planar
   regions its queries make, named by index. A view's results stay valid
   until it is released; a view does not outlive its model. */
typedef struct HuakView HuakView;
/* The camera's frame as OCCT builds it: screen x and y and the unit vector
   toward the viewer; a focus of zero for orthographic projection. */
typedef struct {
  double x[3], y[3], eye[3];
  double focus;
} HuakFrame;
/* Where the camera puts a point: its screen position and its depth toward
   the viewer. */
typedef struct {
  double x, y, depth;
} HuakLook;
/* A face's point as the camera sees it, and the face's unit normal there as
   oriented in its shape; `defined` is zero where the normal is not, as at a
   cone's apex. */
typedef struct {
  HuakLook look;
  double normal[3];
  int defined;
} HuakSample;
/* Where a line of sight meets a face: the depth and the face's parameters. */
typedef struct {
  double depth;
  double u, v;
} HuakSighting;
/* Where a line of sight meets a root shape. */
typedef struct {
  size_t source, face;
  double depth;
  double u, v;
} HuakShapeHit;
typedef struct {
  const size_t *items;
  size_t count;
} HuakIndices;
/* Lists of numbers: list k at values[offsets[k] .. offsets[k + 1]]. */
typedef struct {
  const size_t *offsets;
  const double *values;
  size_t count;
} HuakRows;
/* Paths, laid out as HuakRows. */
typedef struct {
  const size_t *offsets;
  const HuakPathCommand *commands;
  size_t count;
} HuakPaths;
typedef struct {
  const size_t *offsets;
  const HuakSighting *items;
  size_t count;
} HuakSightings;
typedef struct {
  const size_t *offsets;
  const HuakShapeHit *items;
  size_t count;
} HuakShapeHits;
/* No face, where a record names one. */
#define HUAK_NO_FACE ((size_t)-1)
/* A piece of a face's outline, where the line of sight grazes the face and
   the face folds over in the image: a curve traced on the face, with its
   curve on the face, or where the outline runs along an edge of the face,
   the curve `edges` names for that edge; and the face's index in its
   shape. */
typedef struct {
  size_t curve;
  size_t face;
} HuakRim;
typedef struct {
  const HuakRim *items;
  size_t count;
} HuakRims;
/* An edge of a root shape: how many of the shape's faces it bounds, the
   first two of them (HUAK_NO_FACE past `faces`), whether it closes the
   single face it bounds on itself, and its kind as OCCT's continuity across
   it gives it: HUAK_SEAM where the faces meet with continuous curvature,
   HUAK_SMOOTH with a continuous tangent plane only, otherwise HUAK_EDGE. */
typedef struct {
  size_t curve, faces;
  size_t face[2];
  int closed;
  int kind;
} HuakEdge;
typedef struct {
  const HuakEdge *items;
  size_t count;
} HuakEdges;
/* A curve where two root shapes meet, and the face of each it lies on. */
typedef struct {
  size_t curve;
  size_t face[2];
} HuakSection;
typedef struct {
  const HuakSection *items;
  size_t count;
} HuakSections;
typedef struct {
  size_t first, second;
} HuakPair;
/* Bounds in the projection plane; `empty` when there is nothing to bound. */
typedef struct {
  double x0, y0, x1, y1;
  int empty;
} HuakBox;
/* An image, whole as trimmed or between two of its parameters. */
typedef struct {
  size_t image;
  int whole;
  double first, last;
} HuakPiece;
/* A layer at a point of the image: a face that the line of sight through
   the point meets, as root shape and face index, which way it turns there
   (1 toward the viewer, -1 away), and where it meets it: the depth and the
   face's parameters. */
typedef struct {
  size_t source, face;
  int facing;
  double depth, u, v;
} HuakLayer;
/* A place to cut an image although no other image crosses it there, as
   where its curve passes through a face of another shape. */
typedef struct {
  size_t image;
  double parameter;
} HuakCut;
/* An image that runs along an arc: the part [first, last] of the image's
   planar curve that the arc covers; where the arc is a stretch along which
   the image runs within tolerance of another whose curve bounds layers,
   beyond which end of the part the image leaves the stretch (1 its last,
   -1 its first), otherwise 0;
   where the image's curve stands over the arc's middle, its depth there
   and its tolerance; and the faces the curve lies on, as root shape and
   face index (HUAK_NO_FACE where fewer). */
typedef struct {
  size_t image;
  double first, last;
  int leaves;
  double depth, tolerance;
  size_t source[2], face[2];
} HuakArcOrigin;
/* An arc of the arrangement of images: a piece of the images between the
   points where they cross, meet or end. (x, y) is its middle; the images
   that run along it are origins[first_origin .. first_origin +
   origin_count). Its left is the left of the way its own curve runs. */
typedef struct {
  double x, y;
  size_t first_origin, origin_count;
} HuakArc;
typedef struct {
  const HuakArc *items;
  const HuakArcOrigin *origins;
  size_t count;
} HuakArcs;
/* The cells of an arrangement: the parts of the plane that its arcs
   bound, one for each closed path of arcs around such a part, so that a
   part with holes in it is a cell for each of its boundaries. Over a cell
   the line of sight meets the same faces in the same order: those of cell
   k, front to back, are layers[offsets[k] .. offsets[k + 1]], where the
   line of sight through a point inside it meets them. Arc k has cell
   left[k] on its left, the left of the way it runs, and right[k] on its
   right; `arcs` counts them. */
typedef struct {
  const size_t *offsets;
  const HuakLayer *layers;
  size_t count;
  const size_t *left, *right;
  size_t arcs;
} HuakCells;
/* An arc run its own way, or the other way where `reversed` is set. */
typedef struct {
  size_t arc;
  int reversed;
} HuakTurnedArc;
/* A region's area and centroid, and its principal moments of inertia about
   the centroid with their axes. */
typedef struct {
  double area;
  double center[3];
  double moments[3];
  double axes[3][3];
} HuakMoments;
/* The regions that sets of arcs bound: the regions of set k are regions
   sets[k] .. sets[k + 1], each a connected region with its outline, the
   closed paths commands[offsets[r] .. offsets[r + 1]], its bounds, and its
   area, centroid and principal moments with their axes. */
typedef struct {
  const size_t *sets;
  const size_t *offsets;
  const HuakPathCommand *commands;
  const HuakBox *bounds;
  const HuakMoments *moments;
  size_t count;
} HuakRegions;
/* Status codes. Each failure writes a message to `error` when it is non-null
   and `capacity` is nonzero, NUL-terminated and truncated to fit. */
#define HUAK_SPACE_OK 0
/* OCCT reported a failure. */
#define HUAK_SPACE_FAILED 1
#define HUAK_SPACE_OUT_OF_MEMORY 2
/* A required pointer was null, or a count and its array disagree. */
#define HUAK_SPACE_INVALID_ARGUMENT 3
/* An index names no shape, face, curve, image or region. */
#define HUAK_SPACE_OUT_OF_RANGE 4

/* The major version, in the high 16 bits, matches the entry point; the minor
   version counts entries appended to the table since. */
#define HUAK_SPACE_ABI_VERSION 0x00060000u

/* Contract for every entry.

   Pointers: inputs and nonempty input arrays must be readable for the call
   and are not retained; an array may be null when its count is zero. Outputs
   must be writable. Coordinates are in points.

   Ownership: `build` returns a model and `view` a view, each released once
   with `release_model` or `release_view`; releasing null does nothing. Release
   a model's views before the model. Arrays a view query returns belong to the
   view and stay valid until it is released; the indices of curves, images
   and regions name objects the view holds. Model queries write only into the
   caller's storage.

   Threads: different models and their views may be used from different
   threads at the same time; one model and its views must not be. */
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  /* HUAK_SPACE_ABI_VERSION of the library. */
  uint32_t abi_version;
  /* The size of this table in the library; entries past a host's own table
     are newer ones it does not know. */
  uint32_t size;
  int (*build)(const HuakModelShape *, size_t node_count, const size_t *roots,
               size_t count, double tolerance, HuakModel **, char *error,
               size_t capacity);
  void (*release_model)(HuakModel *);
  int (*shape)(const HuakModel *, size_t source, HuakShape *, char *error,
               size_t capacity);
  /* Whether two root shapes are the same shape. */
  int (*same)(const HuakModel *, size_t first, size_t second, int *,
              char *error, size_t capacity);
  int (*face)(const HuakModel *, size_t source, size_t face, HuakFace *,
              char *error, size_t capacity);
  int (*normal_turns)(const HuakModel *, size_t source, size_t face,
                      const HuakUV *, size_t count, HuakNormalTurn *,
                      char *error, size_t capacity);
  /* For each segment, the fraction of the way along it where the face's
     normal n gives n . direction = value, to within `tolerance`; NaN where
     the ends give no change of sign or the normal is undefined. */
  int (*roots)(const HuakModel *, size_t source, size_t face,
               const HuakSegment *, size_t count, const double direction[3],
               double value, double tolerance, double *, char *error,
               size_t capacity);

  /* A camera looking along -eye at the origin, with `x` horizontal on the
     screen; a focus of zero for orthographic projection. */
  int (*view)(HuakModel *, const double eye[3], const double x[3],
              double focus, HuakView **, HuakFrame *, char *error,
              size_t capacity);
  void (*release_view)(HuakView *);
  int (*look)(HuakView *, const HuakXYZ *, size_t count, HuakLook *,
              char *error, size_t capacity);
  int (*samples)(HuakView *, size_t source, size_t face, const HuakUV *,
                 size_t count, HuakSample *, char *error, size_t capacity);
  /* All points where the lines of sight through screen points meet a face,
     in its intersector's order. */
  int (*sightings)(HuakView *, size_t source, size_t face, const HuakXY *,
                   size_t count, HuakSightings *, char *error,
                   size_t capacity);
  /* All points where the lines of sight through screen points meet the root
     shapes: shape by shape, each in its intersector's order. */
  int (*rays)(HuakView *, const HuakXY *, size_t count, HuakShapeHits *,
              char *error, size_t capacity);
  /* The edges of a root shape, as space curves, in exploration order. */
  int (*curves)(HuakView *, size_t source, HuakIndices *, char *error,
                size_t capacity);
  /* Each distinct edge of a root shape with the faces it bounds. */
  int (*edges)(HuakView *, size_t source, HuakEdges *, char *error,
               size_t capacity);
  /* The outlines of a root shape's faces as the camera sees them, as OCCT
     traces them face by face. A face whose outline runs along one of its
     edges folds over along that edge's curve. */
  int (*rims)(HuakView *, size_t source, HuakRims *, char *error,
              size_t capacity);
  /* The curves where two root shapes meet. */
  int (*sections)(HuakView *, size_t first, size_t second, HuakSections *,
                  char *error, size_t capacity);
  /* The image of each curve, or of its conversion to a spline, which keeps
     a line's perspective parameter; -1 where the image is a point. */
  int (*project)(HuakView *, const size_t *curves, size_t count, int spline,
                 double tolerance, ptrdiff_t *images, char *error,
                 size_t capacity);
  /* For each pair of a curve and a root shape, the spline parameters where
     the curve passes through one of the shape's faces. */
  int (*pierce)(HuakView *, const HuakPair *, size_t count, HuakRows *,
                char *error, size_t capacity);
  /* Path commands for pieces of images, within `tolerance`. */
  int (*approximate)(HuakView *, const HuakPiece *, size_t count,
                     double tolerance, HuakPaths *, char *error,
                     size_t capacity);
  /* The curves on a face where the normal makes `angle` with `direction`,
     as OCCT traces them: space curves with their curves on the face. Each
     end of one lies on an edge of the face, at a point where the face's
     parametrization is singular, or at an end of another; OCCT leaving a
     curve open elsewhere fails the call. */
  int (*contours)(HuakView *, size_t source, size_t face,
                  const double direction[3], double angle, HuakIndices *curves,
                  char *error, size_t capacity);
  /* Arranges the images into arcs, which the view keeps in place of any
     earlier arrangement: the pieces of them between the points where they
     meet, cross or come within tolerance of each other in the plane. Curves
     that meet in space meet at one point of it; an image is also cut at each
     of `cuts`. */
  int (*arrange)(HuakView *, const size_t *images,
                 size_t count, const HuakCut *cuts, size_t cut_count, HuakArcs *,
                 char *error, size_t capacity);
  /* The cells of the latest arrangement, each with the layers over it.
     Turning at each vertex onto the arc that leaves it next clockwise runs
     around the part of the plane on the left of the arcs; the order in which
     arcs leave a vertex is that in which they cross the circle of its
     tolerance, beyond which they stand apart. A cell's layers are found
     along the line of sight through the point at the middle of the arc of
     its boundary that stands farthest from the other arcs, halfway from the
     arc to the nearest of them. */
  int (*cells)(HuakView *, HuakCells *, char *error, size_t capacity);
  /* The outline of each set of arcs, set k arcs[offsets[k] .. offsets[k + 1]],
     that bound a region lying to their left as they are turned: closed
     paths within `tolerance`, which filled where they wind around a point
     are the region. */
  int (*fill)(HuakView *, const size_t *offsets, const HuakTurnedArc *arcs,
              size_t count, double tolerance, HuakPaths *, char *error,
              size_t capacity);
  /* As `fill`, with each set's region apart from the others it does not
     touch: each connected region with its own outline, holes included, its
     bounds and its moments. */
  int (*regions)(HuakView *, const size_t *offsets, const HuakTurnedArc *arcs,
                 size_t count, double tolerance, HuakRegions *, char *error,
                 size_t capacity);
} HuakProjectionV6;

/* The table is immutable and valid until the library is unloaded. Incompatible
   changes to the table or any input/output structure require a new entry point. */
const HuakProjectionV6 *huak_space_api_v6(void);
#ifdef __cplusplus
}
#endif
#endif
