# Nodegraph for Huak

Independent Huak package for node-and-arrow diagrams. It is not part of the
huak standard library: huak neither embeds it nor registers it in `catalog`.

- entry: `nodegraph.huak`
- modules: `nodegraph/`
- examples: `examples/`
- acceptance: `zig run -OReleaseSafe tests/acceptance.zig -- ../../zig-out/bin/huak ../../libtypst/target/release/libtypst.dylib` from this directory
- [Executable examples and regression cases](tests/fixtures/)

The `drawing`-block entry is a `scene` value. Save this script under `examples/`
(the import path is relative to the script):

```huak
import paint.*
import "../nodegraph.huak".*

d := scene()
drawing d do
    a := place typ[$A$] at grid(0, 0)
    b := place typ[$B$] at grid(1, 0)
    link a to b
end
default d.picture
```

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
