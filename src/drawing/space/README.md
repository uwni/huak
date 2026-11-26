# Projecting script-built geometry

`import space as s` loads the modeling functions. Construct a list of shapes, then call
`s.project(shapes, view, tolerance:0.01pt, faces:true)`. All shapes in the list participate
in the same visibility calculation. Source and face indices start at zero.

- Use the same `--`, `-- cycle`, `&`, `path`, `closed`, `reverse` and
  `geometry.bezier` in two or three dimensions. `rectangle(origin,width,height)`,
  `geometry.circle(center,radius)`, `ellipse(center,rx,ry)` and
  `arc(center,radius,start,sweep)` accept a two- or three-component origin or center.
  With a 2D center the conic is an editable cubic `path`. With a 3D center it
  is a `shape` with an analytic conic in a plane parallel to XY. A negative arc
  sweep runs clockwise as seen from +Z. Hobby interpolation (`~~`) is planar.
- `s.profile(path,plane)` places an existing 2D path in space, preserving its
  lines and Bézier controls. A `Plane` maps `(x,y)` to `origin + x*u + y*v`.
  `s.face(contour)` makes a planar face. A compound path can supply the outer
  boundary followed by oppositely oriented holes. The adapter constructs OCCT
  wires from these boundaries.
- `s.extrude(contour,displacement)`, `s.revolve(contour)` and `s.sweep(contour,guide)`
  accept open curves for sheets, and closed planar contours or faces for solids.
  The default placement of a 2D path is XY, except for revolution, where XZ
  gives the usual radius–height profile about Z. A positioned 3D shape keeps
  its coordinates. Revolution accepts a center, axis and angle. Supply a connected,
  tangent-continuous guide to sweep. `s.loft(sections,solid:true)` joins successive
  closed cross-sections into a solid. Omit `solid:true` for an uncapped shell.
  See the [semicircle example](../../../examples/space/profiles.huak).
- `s.surface(rows)` is one face through a grid of points: `rows` lists rows of
  as many points, at least two by two, and OCCT interpolates the C2 B-spline
  surface through them all (`GeomAPI_PointsToBSplineSurface`). A graph
  z = f(x, y), a parametric surface or measured heights are grids of their
  points; the script samples them.
- `s.box(width,depth,height)` extrudes an ordinary rectangle. `s.sphere(radius)`,
  `s.cylinder(radius,height)` and `s.cone(base,height,top:0pt)` use analytic
  surfaces. A positive top radius produces a frustum.
- Use the existing `transform` module and `regions` operators. For example,
  `transformed(body,rotate(45deg,axis:(0,1,0)))` tilts a solid. `scale(k)` scales
  uniformly in any dimension, `scale(x,y)` preserves Z and `scale(x,y,z)`
  sets all three factors. `a union b`, `a inter b` and `a minus b` operate on
  two planar paths or two model shapes. A model stores references to its operands,
  and projection constructs shared model nodes once per call.
- `torus(major,minor)` constructs a ring torus around Z. `on_surface(shape,uv,face:0)`
  draws a path in the chosen surface's native parameter coordinates. A torus uses radians
  on both axes and accepts unwrapped parameters across complete turns. For trimmed
  surfaces, supply a path within the intended face.
- `orthographic(azimuth,elevation)` and `perspective(azimuth,elevation,focus)` look at
  the origin. Keep the geometry and its control points in front of the perspective eye.
- `result.layers` is in **back-to-front paint order**. In each layer, fill its `faces`
  first and stroke its `lines` next. Each face fragment carries its original `source`
  and `face` indices and its 2D `region`, including holes. Ordinary RGBA fills then
  composite in SVG and PDF. See the [intersecting plates](../../../examples/space/plates.huak)
  and [sphere pierced by a cylinder](../../../examples/space/solids.huak).
- A layer groups portions with the same number of sheets in front of them along the
  viewing ray. A face can span several layers as it passes behind other geometry.
  Both crossings of a closed surface contribute, even when they share a face index.
  For sheets at the same depth within OCCT's modeling tolerance, the earlier input
  shape paints in front. Standalone ink on a surface paints over its fill.
- `result.visible_faces` gives the front layer's faces. Pass `faces:false` for
  linework alone. The drawing tolerance controls the conversion of projected
  curves to cubic paths. OCCT uses its own intersection tolerances.

For textbook shading under orthographic projection, pass a direction towards
the light source, for example `light:(-1,-2,3)`, and paint the visible faces
with `s.shaded(faces, inks)`, which takes `behind`, `paper` and `translucent`
as `s.toned` does below. Set `spot:24deg` to add a gleam. Its boundary
is where the surface normal makes that angle with the light/view half-vector
(Stroila, Eisemann and Hart, *Clip Art Rendering of Smooth Isosurfaces*,
Eq. 13). Huak traces this contour on the face as it traces the others (see
below), and fits an ellipse to each connected projected highlight, with the
area and principal moments OCCT measures, for the radial color falloff and
clips it to the visible highlight boundary. See the [highlight example](../../../examples/space/highlight.huak).

With `smooth:true` the light is continuous instead of banded, and each front
region becomes its own face carrying a field of n·l and of the gleam
(`shading.zig`). Huak computes the fields; OCCT evaluates the surfaces, their
normals and normal derivatives, finds where the contour crosses each cell side
and where lines of sight meet a face, all in batches. A plane's field is constant; a cylinder seen across its axis
varies along one direction, as a profile of samples. A cone's rulings meet
at its apex, which OCCT names, and each carries constant light, so its field
is a fan around the apex's projection: constant along each ray, and between
neighbouring rulings linear along the chord joining their far ends. The
rulings halve until a closed bound keeps the fan within `e / 8` of the light;
outputs draw it within the rest, as one patch per pair of rulings in a PDF
patch mesh and as triangles from the apex in SVG (`src/drawing/conic.zig`).
A cone seen along one of its rulings has no fan. It and other faces get
tensor-product Bézier patches over a grid of their parameters, each
interpolating the projected surface and the light at sixteen samples. Cells
turn the normal by at most `sqrt(4e)` for an accuracy `e` of 1/256, so that
bilinear interpolation of each patch's corner values, which a PDF patch mesh
paints, stays within `e`; where the gleam can be positive, finer patches carry
it, and elsewhere it is 0. Both lights thus lie on the same patches, as a
cone's lie on the same rays, so flattening the gleam over n·l combines them
patch by patch. Cells crossing the contour keep their front part, cut where n·v
vanishes, and skirts carry the light of contour and face-boundary sides past
the outline's tolerance. SVG output subdivides the patches into triangles
(`src/drawing/patches.zig`).

An open sheet may show its back, the side its normal points away from;
which side a line of sight meets is the arrangement's to tell. A face that
shows one side is shaded with that side's normal. A face that shows both
gets a sheet of cells for each side, and each region takes the cells of
both that nothing of the face lies in front of, judged at their centers as
for a face that covers itself: where a sheet folds away at its outline, the
side beyond lies behind the side before.

The script may give a field of its own, `f(point, normal)`, with the point
in world coordinates and the normal of the side that shows. The engine
knows nothing of what it means: it samples it through the VM, as
`transform.mapped` samples a point mapping, at the nodes the patches
already use, recovering each node's world point from its screen position
and depth along the camera's axes. With a field every face gets patches,
since a field can vary in every direction. Patches start at most `step`
apart on the page in their samples and halve, square by square, while
their corner values, interpolated bilinearly as a PDF patch mesh paints
them, stray from the field at their samples by more than the tolerance;
a change narrower than the step may go unseen, and a square the lattice
cannot halve again reports that the field is too rough for its tolerance.
`s.colored(faces, colors, levels)` paints the field through color stops,
optionally with the light over it.

A few tones can stand in for the light. `s.page_light(camera)` is a direction
that keeps its place on the page, from the upper left by default, and
`s.Tones()` pairs isophote cuts with tones of the ink. Project with
`light: s.page_light(camera), isophotes: tones.cuts`, then
`s.toned(faces, inks)` cuts each face where its tone changes and
`s.flat(faces, inks)` gives each face one color, the average of those tones
by the area each takes on the page. Both are ordinary script in
`stdlib/space/solids.huak` over the isophote bands. A reader anti-aliases every fill
by itself and lets what is under two fills show along the edge they share, so
the pieces of a solid are not filled side by side: pieces of one color go
into one path, and the colors are laid from the darkest up, each over every
piece at least as light, which leaves under any edge only colors between its
two sides.

Each solid is a picture with the ink's opacity (`object.opacity`), so an ink
that is not opaque lets the paper and the picture `behind` show, such as the
lines the faces hide. By default the result goes through
`object.flatten_transparency` (`src/drawing/transparency.zig`) onto `paper`,
and the output holds nothing translucent. With `translucent: true` the layers
stay: SVG gives each group an `opacity`, and PDF makes each one a
transparency group (see `src/render/pdf/README.md`). Over white paper the two
look the same. See the [textbook example](../../../examples/space/textbook.huak).
`s.shaded` builds its solids the same way, with the gleam as translucent white
over opaque shading.

Contours, the outlines where lines of sight graze a face, its isophotes and
the boundaries of its highlights, are marched on a grid of the face's
parameters (`contours.cpp`), with OCCT's contour function deciding the side of
each node and placing every point. The function is computed from OCCT's own
point and normal exactly as `Contap_SurfFunction` computes it
(`contour_function.cpp`; `tests/space_contour_function.cpp` compares the two
bit for bit), because the bound on its rounding needs the normal's length,
which `Contap_SurfFunction` does not give. That bound follows from floating-point filter error analysis of the
computation, from the lengths of the normal and the line of sight, and every
decision rounding could tip uses it: a node's side, where the contour crosses
itself or meets an edge, where Newton's method stops. The grid halves where the normal turns,
holds the point where the function's gradient vanishes in a cell whose
corners alternate sides, so that a contour crossing itself there is cut
there, and is halved again where tracing finds the contour leaving a
triangle between two nodes. Each traced piece is sampled evenly; where the
contour lies on a line or a circle within what OCCT tells apart, it is that
OCCT curve, as a sphere's outline is, and else a spline fitted to within
that. Between each two samples the contour is measured against the curve
where it stands farthest, as OCCT's minimizer finds it, and the edge has the
tolerance measured, never less than what OCCT tells apart. Pieces end on the
face's edges, at its singular points and where the contour crosses itself.

Projection (`linework.zig`) draws each curve whole where its own shape decides
its visibility, and otherwise splits it wherever it crosses another curve's
image or pierces another shape, ranking each piece by the sheets in front of
its middle. The adapter arranges the images in the plane (`arrangement.cpp`):
they meet where they come within their tolerances, run along each other
where they are proven to stay within them, and are cut wherever they meet,
so that the arcs between the vertices bound the cells of the plane. One line
of sight through each cell finds the sheets in front of it; the drawing's
faces are the cells grouped by the face each sheet in front shows, with the
lighting contours among the arcs, excluding the empty background. This
preserves the boundary relationship at isophote tangencies; lighting does not
turn silhouettes into interior cut edges.

A view asks where its lines of sight meet the faces through one index of
their images (`sights.cpp`), built on its first such question: the middles
of arcs, the points of cells and the light's culling all ask it. A plane,
quadric or torus face is asked of OCCT's line and face intersector only
where its box holds the point. Any other face keeps a grid of its
parameters (`sights_grid.cpp`), halved where its cells bend, each cell's
image widened by how far the surface may stand off its triangles, as
OCCT's polyhedron estimates it, in OCCT's BVH; each triangle near the point
starts OCCT's curve and surface solver once, and OCCT's classifier keeps the
roots in the face. OCCT's own intersector would start its solver from every
polyhedron edge near the line, over a hundred times for each crossing of a
free-form face at a slant, for every face and every point. Near an outline,
where the line crosses the surface twice close together, the solver also
starts on either side of the outline and where the surface's osculating
quadric puts the second crossing.

### Choosing a line style

Each entry in `result.lines` has a 2D `curve`, a `kind` and a separate
`visible` flag. The flag changes along a curve wherever occlusion starts or ends.

| `kind` | Geometry |
| --- | --- |
| `"edge"` | Sharp model edge or face boundary |
| `"outline"` | View-dependent apparent contour of a surface, such as the outline of a sphere |
| `"intersection"` | A section curve generated where the faces of two input shapes meet |
| `"smooth"` | Tangent join between faces |
| `"seam"` | Smoothly sewn join classified by OCCT |
| `"curve"` | A curve supplied in the model list |

For an intersection, `source` and `other_source` index the two shapes in input
order. All other lines have one `source` and an `other_source` of `-1`. Curves
crossing only in the image retain their original kinds. A point contact or a
shared area has no unique section curve.

For the **outline of the whole scene**, import `space.silhouette` and call
`result.silhouette()`, or call `s.silhouette(result)` with `import space as s`.
The function takes the union of `result.visible_faces` when called. The path
includes the outer edges of a box and the boundary of any visible hole.
A projection with `faces:false` has an empty face list and yields an empty path.
See [different pens for contours, edges and intersections](../../../examples/space/solids.huak).

## Desktop

The same desktop executable handles 2D and 3D. At startup it opens
`libhuak_space.dylib` (macOS) or `libhuak_space.so` (Linux) once. It looks in
`../lib/` relative to the executable and in the executable's directory.
The adapter links against OCCT. The system loader must be able to find those
libraries, for example beside the adapter or via `DYLD_LIBRARY_PATH` on macOS
and `LD_LIBRARY_PATH` on Linux. If loading fails, 2D drawing and model construction
remain available. Calling `space.project` then reports the missing backend.

Build the adapter with CMake and the [OCCT 8.0.1 SDK](https://github.com/Open-Cascade-SAS/OCCT/releases/tag/V8.0.1):

```sh
zig build space-backend -Docct="$OCCT_PREFIX"
zig build test-space -Docct="$OCCT_PREFIX"
```

CMake can also discover a system SDK when the prefix is omitted. The native
C++ toolchain uses the SDK's imported libraries. The versioned C entry point
`huak_space_api_v7` returns the function table. The adapter only runs OCCT:
it builds a model and opens views of it, and each query is one OCCT operation
over a batch, such as hidden-line removal of a shape, the image of curves,
their crossings, where lines of sight meet the shapes, the partition of the
plane by images, merging regions, or a region's outline and moments. What to
ask and what to make of the answers is decided in Zig (`linework.zig`,
`shading.zig`); nothing that OCCT provides is computed again in Zig. Huak
checks every index the adapter returns against its arrays before use. Each
projection releases its view and model before returning.

The header (`projection.h`) states the boundary contract, as libtypst does:
named status codes tell failures, exhaustion, null arguments and indices out
of range apart, with a message; the table carries its ABI version and size,
and the loader rejects another major version or a smaller table; inputs are
borrowed for the call, a view's results live until the view is released,
and releasing null does nothing. Different models may be used from different
threads at once, one model and its views from one thread at a time. Watch builds and workers borrow the table
for the lifetime of their host session.
Open CASCADE Technology is licensed under LGPL 2.1 with the Open CASCADE exception.
The adapter installation includes the [notice and license texts](licenses/).

## Optional Playground build

The public Playground defaults to the 2D build. To reproduce the single-threaded WASI
test, prepare a local directory with the following layout. Use the checksums in the
upstream [kernel pin](https://github.com/SecondMouseAU/OCCTSwift/blob/v4.0.0-kernel.8/Scripts/wasm-kernel-pin.txt)
and [toolchain pins](https://github.com/SecondMouseAU/OCCTSwift/blob/v4.0.0-kernel.8/Scripts/wasm-toolchain-versions.txt).

| Local path | Contents |
| --- | --- |
| `libOCCT-wasm.a`, `occt-headers-wasm/` | Extract `libOCCT-wasm.tar.gz` from [OCCTSwift v4.0.0-kernel.8](https://github.com/SecondMouseAU/OCCTSwift/releases/tag/v4.0.0-kernel.8), based on OCCT 8.0.1 |
| `wasi-std-threading.hpp` | [The matching single-threaded OCCT build header](https://github.com/SecondMouseAU/OCCTSwift/blob/v4.0.0-kernel.8/Scripts/wasm-shims/wasi-std-threading.hpp) |
| `WASI.sdk/` | The `wasm32-unknown-wasip1/WASI.sdk` directory inside the pinned Swift 6.4 Wasm SDK |
| `wasi-sdk/` | Extract [WASI SDK 34](https://github.com/WebAssembly/wasi-sdk/releases/tag/wasi-sdk-34) for the build host here |

```sh
zig build playground test-playground -Dwasm-occt=/path/to/toolkit --prefix target/playground-3d
```

This produces one Wasm module, using the same drawing adapter as the desktop. The check
runs the modeling, visibility and lighting tests and renders the 3D examples through the Playground
entry point. This build requires WebAssembly exception handling.

The Wasm module statically incorporates OCCT and OCCTSwift modifications. For redistribution
under LGPL 2.1 §6(a), supply the matching OCCT sources and patches, the Huak application
source or linkable objects, and the instructions and materials needed to relink. The
[pinned kernel build](https://github.com/SecondMouseAU/OCCTSwift/tree/v4.0.0-kernel.8/Scripts)
identifies the upstream sources, patches and build procedure. The local test install copies
the license texts; packaging corresponding sources for public distribution is a separate step.
