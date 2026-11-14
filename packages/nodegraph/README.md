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

The canvas covers every drawn object; the `margin` option (default `0pt`)
adds whitespace on every side. A `floating` node takes no grid cell, but a
visible one is still drawn in full and sizes the canvas. Hidden objects keep
their layout box; hidden floating items and the debug overlay never size the
canvas. Grid,
`between` and absolute edge endpoints snap to the outline of the node they
reach; `relative` endpoints and ports are exact anchors.

Device-style nodes declare port columns, for example
`{"ports": {"west": 4, "east": 4}, "port_pitch": 20pt}`, and edges attach with
`port(name, "west" or "east", index)`, where index 0 is the topmost port.
`bus_options(rule, font_size, color, label)` returns the edge options of a
circuit bus: a stroke 2.2 rules wide, a slash at the middle, a solid head and
a label on the left.

Edges can reach into typeset content. Give an element a Typst label, such as
`#box[$a$] <a>`, and `part(node, "a")` addresses it, with a scene handle or
`named(name)` for the node. A part is an ordinary coordinate: `link` accepts it
as well as node handles, and `edge`, `between` and `relative` take it like any
other. An edge snaps to the element's box, padded by the node's `inset` and
widened by its `outset` as the node's own outline is; `"snap": false` on the
node keeps the exact aim point. Parts that start on one baseline, such as the
entries of a matrix row, share the mean height of their centers, so edges
along a row stay level however tall each entry is.

Matrices are laid out by Typst: put the whole matrix in one node and link its
entries, so brackets stretch and rows align on their baselines. Math has no
label syntax, so a helper boxes and labels an entry: a function in a
`typ.module`, which Typst code calls as `huak.parts.mark`. Call it without `#`: a `;`
written right after a `#` expression ends that expression instead of the
row. Leave room between linked entries; when their padded boxes touch, the
connector is fully enclosed and reported as an error.

```huak
import paint.*
import "../nodegraph.huak" as nodegraph
import "../nodegraph.huak".{scene, place, link, grid, part}

parts := typ.module[#let mark(name, body) = [#box($body$)#label(name)]]
d := scene()
nodegraph.drawing d do
    m := place typ[$mat(delim: #none, column-gap: #4em, row-gap: #3em,
        huak.parts.mark("G", G), huak.parts.mark("im", "im"(f));
        huak.parts.mark("q", G / "ker"(f)), huak.parts.mark("H", H))$] at grid(0, 0)
    link part(m, "G") to part(m, "im") with {"label": typ[$f$]}
    link part(m, "q") to part(m, "H")
end
default d.picture
```

[examples/diagrams.huak](examples/diagrams.huak) draws a commutative square
this way.

Brace, bracket and paren nodes stretch a Typst glyph over the node. The
node's `fill` colors the glyph, and the `style` shape option takes a
`typ.module` whose `style` function is applied around it as `typ.show` would, so the
caller's text settings, such as
`set text(size: 14pt)`, give its stroke weight:
`{"shape": "brace", "shape_options": {"dir": "bottom", "style": theme}}`.
`stretched_glyph(kind, extent, side, fill, style)` typesets the same glyph
directly.

Arrowheads bend along smooth routes by default. Their ordinary local geometry
is transformed together with its clearance mask; arrow styles remain in this
package, while `transform.bent` supplies the general geometric operation.
Paths bend before stroking with the original pen, so bending does not stretch
the line width of open heads or harpoons.
Use `mark("solid", 1, false, {"bend": false})` for rigid tangent placement.
Relationship symbols and custom pictures retain rigid placement unless
`"bend": true` is explicitly requested. Custom text must first be converted
with `outlines` if it is to bend; ordinary diagram labels remain native text.

A hook leaves the end of the stroke and curls back to its left, as Fletcher
draws it. In `hook->` it sits at the tail, reversed, so it turns back outside
the edge as in ↪; a reversed hook is mirrored rather than turned, so it keeps
that side. At the tip a hook steps back by its radius: its apex meets the end
and the stroke stops where the hook starts, unless `tip_end` says otherwise.

[examples/bending.huak](examples/bending.huak) compares six arrow styles with
and without bending. Export it with `--output=comparison.svg` or `.pdf`.
The example uses the normal edge renderer. At masked terminal marks, the shaft
ends at the base of the mask instead of continuing through the head to its tip.
This common attachment rule uses the original mask without an inset or a
position adjustment. Tail shortening preserves the original dash alignment.
