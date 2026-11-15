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
   each parameter or zero, a cone's semi-angle, and a cylinder's frame, in
   which u is the angle from axis_x toward axis_y. */
typedef struct {
  int kind;
  double u0, u1, v0, v1;
  double u_period, v_period;
  double semi_angle;
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
/* Lists of indices: list k at items[offsets[k] .. offsets[k + 1]]. */
typedef struct {
  const size_t *offsets;
  const size_t *items;
  size_t count;
} HuakGroups;
/* Lists of numbers, laid out as HuakGroups. */
typedef struct {
  const size_t *offsets;
  const double *values;
  size_t count;
} HuakRows;
/* Paths, laid out as HuakGroups. */
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
/* A space curve from hidden-line removal: HUAK_EDGE, HUAK_OUTLINE,
   HUAK_SMOOTH or HUAK_SEAM, and whether it is visible in its own shape. */
typedef struct {
  size_t curve;
  int kind;
  int visible;
} HuakSilhouette;
typedef struct {
  const HuakSilhouette *items;
  size_t count;
} HuakSilhouettes;
/* An edge of a root shape: how many of the shape's faces it bounds, and
   whether it closes the single face it bounds on itself. */
typedef struct {
  size_t curve, faces;
  int closed;
} HuakEdge;
typedef struct {
  const HuakEdge *items;
  size_t count;
} HuakEdges;
/* Whether a space curve is a straight line, and its tolerance. */
typedef struct {
  int line;
  double tolerance;
} HuakCurveInfo;
typedef struct {
  double first, last;
} HuakRange;
/* A point of a space curve at a parameter of its spline, or, with
   `on_surface`, the point of its surface at its parameter curve. */
typedef struct {
  size_t curve;
  double parameter;
  int on_surface;
} HuakCurvePoint;
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
/* An image whose pieces a partition records for its shape. */
typedef struct {
  size_t image, source;
} HuakTracked;
/* A region's area and centroid, and its principal moments of inertia about
   the centroid with their axes. */
typedef struct {
  double area;
  double center[3];
  double moments[3];
  double axes[3][3];
} HuakMoments;
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
#define HUAK_SPACE_ABI_VERSION 0x00030000u

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
  /* Hidden-line removal of a root shape alone: for each kind in the order
     above, its visible curves and then its hidden ones. */
  int (*silhouettes)(HuakView *, size_t source, HuakSilhouettes *,
                     char *error, size_t capacity);
  /* The curves where two root shapes meet. */
  int (*sections)(HuakView *, size_t first, size_t second, HuakIndices *,
                  char *error, size_t capacity);
  /* The image of each curve, or of its conversion to a spline, which keeps
     a line's perspective parameter; -1 where the image is a point. */
  int (*project)(HuakView *, const size_t *curves, size_t count, int spline,
                 double tolerance, ptrdiff_t *images, char *error,
                 size_t capacity);
  int (*curve_info)(HuakView *, const size_t *curves, size_t count,
                    HuakCurveInfo *, char *error, size_t capacity);
  /* The parameter range of each image's planar curve. */
  int (*ranges)(HuakView *, const size_t *images, size_t count, HuakRange *,
                char *error, size_t capacity);
  /* The bounds of images together, with their tolerances. */
  int (*bounds)(HuakView *, const size_t *images, size_t count, HuakBox *,
                char *error, size_t capacity);
  /* The bounds of each region, with its tolerance. */
  int (*region_bounds)(HuakView *, const size_t *regions, size_t count,
                       HuakBox *, char *error, size_t capacity);
  /* For each pair of images, the parameters on the first where they meet,
     points first and then the ends of shared segments. */
  int (*crossings)(HuakView *, const HuakPair *, size_t count, HuakRows *,
                   char *error, size_t capacity);
  /* For each pair of a curve and a root shape, the spline parameters where
     the curve meets the shape's faces. */
  int (*pierce)(HuakView *, const HuakPair *, size_t count, HuakRows *,
                char *error, size_t capacity);
  int (*curve_points)(HuakView *, const HuakCurvePoint *, size_t count,
                      HuakXYZ *, char *error, size_t capacity);
  int (*image_points)(HuakView *, const size_t *images,
                      const double *parameters, size_t count, HuakXY *,
                      char *error, size_t capacity);
  /* Path commands for pieces of images, within `tolerance`. */
  int (*approximate)(HuakView *, const HuakPiece *, size_t count,
                     double tolerance, HuakPaths *, char *error,
                     size_t capacity);
  /* The images of the curves on a face where the normal makes `angle` with
     `direction`. */
  int (*contours)(HuakView *, size_t source, size_t face,
                  const double direction[3], double angle, double tolerance,
                  HuakIndices *, char *error, size_t capacity);
  /* The regions into which images divide the rectangle, or with a null
     rectangle the regions `domain`. Pieces of tracked images join their
     shape's borders, which `merge` can keep. */
  int (*partition)(HuakView *, const HuakBox *rectangle, const size_t *domain,
                   size_t domain_count, const size_t *tools, size_t tool_count,
                   const HuakTracked *, size_t tracked_count, HuakIndices *,
                   char *error, size_t capacity);
  /* A point inside each region. */
  int (*interiors)(HuakView *, const size_t *regions, size_t count, HuakXY *,
                   char *error, size_t capacity);
  /* Each list of regions merged where they share a boundary, except along
     the borders of shape keep[k]; keep[k] < 0 keeps none. */
  int (*merge)(HuakView *, const HuakGroups *, const ptrdiff_t *keep,
               HuakGroups *, char *error, size_t capacity);
  /* Each region's wires as closed paths, within `tolerance`. */
  int (*outlines)(HuakView *, const size_t *regions, size_t count,
                  double tolerance, HuakPaths *, char *error, size_t capacity);
  int (*moments)(HuakView *, const size_t *regions, size_t count,
                 HuakMoments *, char *error, size_t capacity);
} HuakProjectionV3;

/* The table is immutable and valid until the library is unloaded. Incompatible
   changes to the table or any input/output structure require a new entry point. */
const HuakProjectionV3 *huak_space_api_v3(void);
#ifdef __cplusplus
}
#endif
#endif
