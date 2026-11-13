# Mesh PDF encoding

`mesh.zig` encodes a single mesh paint and its curved clipping boundary as a
one-page PDF 1.4 graphic: a Type 4 free-form Gouraud shading over the unit
square, with 32-bit coordinates and 16-bit colors. Vertex alpha uses a PDF
luminosity soft mask with the same triangulation. The page structure is fixed
and contains only numbers and names, so no PDF writing library is needed.

Each encoding writes into one buffer, which is its only allocation. Objects and
the clip's content stream are written directly; the shading records stream
through the Zig standard library's deflate (zlib container) straight into the
same buffer, so neither the uncompressed mesh nor a separate compressed copy is
held. Stream lengths go into fixed-width `/Length` fields once the data is
complete; the unused digits stay as spaces. The buffer starts from a sizing
hint of a quarter of the record bytes and grows or is trimmed as needed.

The deflate state and window (about 288 KiB) live in a `Workspace` that the
caller allocates once and reuses for every stream; the Typst adapter keeps one
per document. Level 4 was chosen by measurement: on the 162,762-triangle
lighting replay it compressed faster and smaller than levels 3 and 5 to 7, and
smaller than the former Rust encoder's output.

Typst has no mesh paint. The Typst adapter imports this graphic through
libtypst's generic PDF page API, places it back in scene coordinates and uses
the existing Typst exporter for the final document. libtypst copies the bytes
during import, and the adapter frees the PDF immediately afterwards, while it
is still the most recent allocation, so an arena allocator can reuse the space.
Ordinary paths and text never pass through this encoder. Mesh geometry and
lighting are supplied by the caller; this module does not compute them. Meshes
retain vector shading; no raster image or SVG fallback is generated.
