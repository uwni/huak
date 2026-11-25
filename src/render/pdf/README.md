# PDF graphics Typst cannot draw

Typst has no patch paint, and its groups have no opacity. For these two the
Typst adapter has an encoder here write a one-page PDF graphic (PDF 1.3 for
direct RGB patches, PDF 1.4 when soft masks are used), imports it
through libtypst's generic PDF page API, places it back in scene coordinates
and uses the existing Typst exporter for the final document. libtypst copies
the bytes during import, and the adapter frees the PDF immediately afterwards,
while it is still the most recent allocation, so an arena allocator can reuse
the space. Everything else stays a native Typst scene: ordinary paths and text
never pass through these encoders, and nothing is rasterized.

A page's structure is fixed and contains only numbers and names, so no PDF
writing library is needed. `syntax.zig` holds what the encoders share: the
number syntax, path construction, the object table with its cross-reference
table, and the `Workspace`. Stream lengths go into fixed-width `/Length`
fields once the data is complete; the unused digits stay as spaces. The
streams that grow with the content are compressed by the Zig standard
library's deflate (zlib container). Its state and window (about 288 KiB) live
in the `Workspace`, which the caller allocates once and reuses for every
stream; the Typst adapter keeps one per document.

## Patch paints: `mesh.zig`

`mesh.zig` encodes a single patch paint and its curved clipping boundary. The
page is the unit square over the extent of the control points. Opaque-stop
patches and fans (converted to corner colors by `color_patches.fromField`) and
`color_patches` go through `encodeColors`: one Type 7 tensor-product patch mesh
with 24-bit coordinates and 16-bit RGB at every corner, no `/Function` and no
soft masks, so the PDF holds nothing translucent. Field patches whose stops
vary in opacity omit fully transparent patches (`Painted.of`) and go through
`encode`: one gray Type 7 mesh whose stops apply through luminosity soft masks
with piecewise-linear transfer functions, plus an opacity mask and coverage
mask as needed. In both encoders, a patch that shares an edge with the one
before it names that edge with flag 1 or 2 instead of repeating it (flag 3
leaves holes in Quartz, and Quartz draws no Type 6 or 7 shading that carries a
`/Function`).

Each encoding writes into one buffer, which is its only allocation. Objects
and the clip's content stream are written directly; the patch records stream
through deflate straight into the same buffer, so neither the uncompressed
mesh nor a separate compressed copy is held. The buffer starts from a sizing
hint and grows or is trimmed as needed. Level 4 was chosen by measurement on
the triangle meshes this encoder wrote before patches: on the 162,762-triangle
lighting replay it compressed faster and smaller than levels 3 and 5 to 7.

Patch geometry and the field are supplied by the caller; this module does not
compute lighting.

## Layers

A picture with an opacity is a layer: what is in it paints over one another
first, and the result is blended into the page once, at that opacity. Paths
that overlap inside the layer do not show through each other, and no edge
between two of them lets the page show. Typst's groups have no opacity, and
nothing here writes a layer: the Typst adapter (`../typst/scene.zig`) submits
the layer's contents as a page of their own, Typst exports that page,
`typst_pdf_page_with_opacity` in libtypst draws it inside one transparency
group at the layer's opacity with krilla, the writer Typst's exporter drives,
and Typst imports the result. A layer therefore holds whatever Typst draws:
text stays text, gradients and the meshes above stay as they are, and a layer
within a layer takes the same route inside the outer one's page.

Each layer's page is the document's page, with the same size and coordinates,
and lies over it without any offset. Quartz paints a gradient pattern in an
imported page in the coordinates of the page that imports it; a page cut to
the layer's extent and moved into place showed its gradients at the wrong
place there, while MuPDF and poppler drew them right. The cost is that every
layer's group spans the page. Each layer also carries its own subsets of the
fonts its text uses. SVG needs none of this: there a layer is a labeled group,
and `../svg/styles.zig` adds the rule that gives it its `opacity`.
