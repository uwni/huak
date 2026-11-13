# Mesh PDF encoding

`mesh.zig` encodes a single mesh paint and its curved clipping boundary as a
one-page PDF 1.4 graphic: a Type 4 free-form Gouraud shading over the unit
square, with 32-bit coordinates and 16-bit colors. Vertex alpha uses a PDF
luminosity soft mask with the same triangulation. Shading records stream
directly into the Zig standard library's deflate (zlib container), so the
uncompressed mesh is never held in memory. Level 4 was chosen by measurement:
on the 162,762-triangle lighting replay it compressed faster and smaller than
levels 3 and 5 to 7, and smaller than the former Rust encoder's output. The
page structure is fixed and contains only numbers and names, so no PDF writing
library is needed.

Typst has no mesh paint. The Typst adapter imports this graphic through
libtypst's generic PDF page API, places it back in scene coordinates and uses
the existing Typst exporter for the final document. Ordinary paths and text
never pass through this encoder. Mesh geometry and lighting are supplied by the
caller; this module does not compute them. Meshes retain vector shading; no
raster image or SVG fallback is generated.

The returned PDF belongs to the caller's allocator; the adapter frees it after
libtypst has copied it during import.
