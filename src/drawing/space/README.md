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
the light source, for example `light:(-1,-2,3)`, and paint each visible face
with `s.shaded(face,ink)`. Set `spot:24deg` to add a gleam. Its boundary
is where the surface normal makes that angle with the light/view half-vector
(Stroila, Eisemann and Hart, *Clip Art Rendering of Smooth Isosurfaces*,
Eq. 13). OCCT traces this contour on the face. Huak fits an ellipse to each
connected projected highlight for the radial color falloff and clips it to
the visible highlight boundary. See the [highlight example](../../../examples/space/highlight.huak).

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

Build with `-Docct=<prefix>` and run `zig build test-space -Docct=<prefix>`.
The tested native installation is OCCT 7.9.3 (Homebrew 7.9.3_1, macOS arm64).
The executable links to the system's OCCT shared libraries. The default build uses
only the two- and three-component vector types and the ordinary 2D drawing engine.
Open CASCADE Technology is licensed under LGPL 2.1 with the Open CASCADE exception.
An enabled desktop installation includes the [notice and license texts](licenses/).

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
