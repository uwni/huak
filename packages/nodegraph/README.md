# Nodegraph for Huak

Independent Huak package for node-and-arrow diagrams. It is not part of the
huak standard library: huak neither embeds it nor registers it in `catalog`.

- entry: `nodegraph.huak`
- modules: `nodegraph/`
- examples: `examples/`
- acceptance: `zig run -OReleaseSafe tests/acceptance.zig -- ../../zig-out/bin/huak ../../libtypst/target/release/libtypst.dylib` from this directory
- [Executable examples and regression cases](tests/fixtures/)

The `drawing`-block entry is a `scene` value. Save this script under `examples/`
(the import path is relative to the script). `paint` exports its own `drawing`
block for pictures, so select the nodegraph names you use and spell the scene
block `nodegraph.drawing`:

```huak
import paint.*
import "../nodegraph.huak" as nodegraph
import "../nodegraph.huak".{scene, place, link, grid}

d := scene()
nodegraph.drawing d do
    a := place typ[$A$] at grid(0, 0)
    b := place typ[$B$] at grid(1, 0)
    link a to b
end
default d.picture
```

The canvas covers every non-floating object; the `margin` option (default
`0pt`) adds whitespace on every side. Hidden objects keep their layout box,
while floating objects such as the debug overlay never size the canvas. Grid,
`between` and absolute edge endpoints snap to the outline of the node they
reach; `relative` endpoints and ports are exact anchors.

Device-style nodes declare port columns, for example
`{"ports": {"west": 4, "east": 4}, "port_pitch": 20pt}`, and edges attach with
`port(name, "west" or "east", index)`, where index 0 is the topmost port.
`bus_options(rule, font_size, color, label)` returns the edge options of a
circuit bus: a stroke 2.2 rules wide, a slash at the middle, a solid head and
a label on the left.

Arrowheads bend along smooth routes by default. Their ordinary local geometry
is transformed together with its clearance mask; arrow styles remain in this
package, while `transform.bent` supplies the general geometric operation.
Paths bend before stroking with the original pen, so bending does not stretch
the line width of open heads or harpoons.
Use `mark("solid", 1, false, {"bend": false})` for rigid tangent placement.
Relationship symbols and custom pictures retain rigid placement unless
`"bend": true` is explicitly requested. Custom text must first be converted
with `outlines` if it is to bend; ordinary diagram labels remain native text.

[examples/bending.huak](examples/bending.huak) compares six arrow styles with
and without bending. Export it with `--output=comparison.svg` or `.pdf`.
The example uses the normal edge renderer. At masked terminal marks, the shaft
ends at the base of the mask instead of continuing through the head to its tip.
This common attachment rule uses the original mask without an inset or a
position adjustment. Tail shortening preserves the original dash alignment.
