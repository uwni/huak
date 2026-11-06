# Mesh PDF encoding

This Huak backend encodes a single mesh paint and its curved clipping boundary.
It uses pdf-writer 0.15.0 for Type 4 Gouraud shading and miniz_oxide 0.8.9 for
compression. Both are locked in Cargo.lock. The result is a PDF 1.4 page in a
unit square, placed back in scene coordinates by the Typst adapter.

Ordinary paths and text never pass through this encoder. The Typst adapter
imports this graphic through libtypst's generic PDF page API and uses the
existing Typst exporter for the final document. No Typst internals or krilla
patches are dependencies here. Mesh geometry and lighting are supplied by the
caller; this module does not compute them.

The Rust allocation returned by `huak_mesh_pdf` is borrowed until
`huak_mesh_pdf_free`. Its capacity travels with the private buffer record so
returning it does not shrink or copy the PDF. The Zig adapter imports the bytes
before releasing them. Raw shading streams are released after compression,
before they are copied into the PDF writer's output buffer.
This private ABI is rebuilt with Huak; it is separate from libtypst's stable API.
Vertex alpha uses a PDF luminosity soft mask with the same triangulation.
Meshes retain vector shading; no raster image or SVG fallback is generated.

`zig build` builds and links the static encoder for the selected target. To
regenerate its private C header:

```sh
cargo run --manifest-path src/render/pdf/Cargo.toml --locked \
  --features headers --bin headers --target-dir target/pdf-mesh
```
