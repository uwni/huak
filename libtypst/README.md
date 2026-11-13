# libtypst

A reusable native library for Typst compilation, content layout, native scenes and SVG/PDF export. A stable C API separates consumers from upstream Rust types and implementation changes. Typst is linked into the library and runs in the caller's process; rendering does not start the Typst CLI or use IPC or WASM.

The implementation uses public Typst 0.15.1 APIs without modifying upstream sources. `Cargo.lock` pins the dependency graph. Library filenames follow platform conventions: `libtypst.so`, `libtypst.dylib` and `typst.dll`.

[Nightly releases](https://github.com/uwni/huak/releases?q=libtypst-nightly) provide the native library and its matching `include/libtypst.h` for Linux x86_64 and macOS arm64. Each release tag identifies the source commit.

## Build and verify

From the repository root, `zig build libtypst` installs the dynamic library in
`zig-out/lib/` and its header in `zig-out/include/`. The default `zig build install`
includes both. Add `-Doptimize=ReleaseSafe` to select Cargo's release profile.

Run in this package directory with Rust 1.92 or later:

```sh
cargo build --locked
cargo run --locked --features headers --bin headers
cargo test --locked --features headers
```

The `headers` tool uses cbindgen to generate `include/libtypst.h` from ordinary Rust C exports and public C records. It is a development tool, not part of the typesetting runtime. The independent acceptance test compiles C11 and C++17 consumers, loads Cargo's current dynamic library, and checks real SVG/PDF output. It requires a C compiler, a C++ compiler and Poppler's `pdftotext`. Test artifacts are written to `target/acceptance/`.

## API surface

`typst_abi_version()` returns the C contract version; `typst_version_info()` also reports capabilities and the library/upstream versions. The current ABI is 1.5, encoded as `0x00010005`, compatible with existing 1.0–1.4 hosts. Public names use `typst_`, `Typst…` and `TYPST_…`.

- `TypstContext` owns immutable font, standard-library, memory-file and input resources. Custom input bytes are copied during creation. Built-in fonts are reused; independent jobs share their context resources. Native plugins remain available by default; callers may explicitly disable them with `TYPST_CONTEXT_DISABLE_PLUGINS`.
- ABI 1.4 adds font discovery (`TYPST_CAP_FONT_DISCOVERY`) through upstream `typst-kit`: `TypstContextOptions.font_dirs` are scanned recursively and `TYPST_CONTEXT_SYSTEM_FONTS` adds the installed system fonts. Discovered fonts are registered by their metadata and read on first use. Font priority is supplied bytes, scanned directories, system fonts, then built-in fonts. Which directories to scan, whether to include system fonts and when to reuse a context are the caller's decisions; the library does not cache scans across contexts. Builds without a file system, such as Wasm, do not report the capability.
- ABI 1.5 adds layout templates (`TYPST_CAP_LAYOUT_TEMPLATES`). Layout options can supply `templates`: independent Typst code that evaluates to a function, such as `body => { set text(red); body }`, each with its own source name, optional setup code whose definitions it can use (the setup's own set and show rules style nothing) and its own bindings. Each template is evaluated once per request. A `TYPST_VALUE_TEMPLATE` binding refers to a template by index and becomes its function, for `#show:` or a direct call; a template's own bindings may refer only to earlier templates. `shows` lists template indices applied around the content like `#show:` rules at its start, outermost first, so rules nearer the content take precedence. Source names must differ across the body, setup and templates.
- `typst_context_compile` compiles an in-memory document. `typst_context_layout` and `typst_context_layout_many` evaluate markup, code or mathematics and return retained layouts with dimensions and baselines. Versioned layout options specify regions and optional setup code. Setup and body keep separate source names and byte ranges while upstream Typst evaluates their shared scope.
- Layout options can supply `bindings/binding_count`, a borrowed array of `TypstBinding` records converted directly to a request-local native Typst scope (`TYPST_CAP_LAYOUT_BINDINGS`). `TypstValueInput` supports none, booleans, signed integers, floating-point numbers, strings, arrays, dictionaries, absolute lengths in points and RGBA colors. These are the library's stable C input kinds, not Typst's Rust enum numbers. Dictionaries naturally serve as namespaces. Setup and body share the supplied values, while imported source files and other requests keep their own scopes. Bindings do not change the immutable context, standard library or `sys.inputs`, and native evaluation caching includes their values. Strings remain data rather than generated Typst code. Input trees are borrowed only until the layout call returns; retained layouts own their resulting content normally.
- `typst_scene_create` accepts complete path arrays, styles, affine transforms, clipping and references to retained layouts or nested scenes. Path, clip and dash arrays are borrowed during the call and converted directly to owned Typst geometry; callers may release or change those inputs after creation returns. Typst constructs the native frames and performs final rendering.
- Documents, layouts and scenes export SVG/PDF. PDF preserves normal text and embedded fonts; SVG follows upstream outline export.
- `typst_layout_outline` explicitly extracts editable glyph and shape geometry in bulk. Its snapshot includes transforms, styles, dashes and shaped-text metadata; it does not change the original selectable layout.
- ABI 1.2 adds optional local-coordinate linear and radial paints to `TypstSceneItemOptions`. Fill and stroke can use independent gradients. Color stops and option views are borrowed until `typst_scene_create` returns.
- ABI 1.3 adds `typst_scene_from_pdf(context, bytes, page, ...)`: import a zero-based PDF page as a retained scene using Typst's native image decoder. The input bytes are copied, and the result can outlive both the input and context. The context only supplies the decoder's environment: the result does not depend on its fonts, files or inputs, so any live context will do. Existing scene transforms, clipping and ordering apply to this graphic. Upstream PDF version and PDF/A/PDF/UA import restrictions still apply.
- `typst_layout_bounds` (ABI 1.1) returns conservative frame-local bounds including logical dimensions and painted overflow. It reuses native text, shape and image extents, including color glyphs and transforms, without outlining content. Clips may make the visible extent smaller.
- `typst_source_block` uses Typst syntax parsing to find a complete leading content/code block. `typst_cache_evict` forwards upstream memoization cleanup for the whole library, not one context.

The public C facade intentionally does not expose the entire Rust API or upstream enum representations. Version-specific `World`, evaluation, layout and graphics construction belong to the internal adapter. Consumer-specific geometry, language evaluation and animation policy remain outside this library.

## Ownership and errors

Contexts, documents, layouts, scenes, outlines, buffers and diagnostics are opaque owned handles. Each has matching `typst_*_retain` and `typst_*_release` functions. Every owned result or retained reference needs one release through the same library instance. Merely copying a pointer does not retain it. Null retain/release calls are allowed.

Layouts, documents and scenes retain the native owned frame or document graph required by their content and can outlive their context. They do not retain the context's entire font catalogue, library and input file collection. Scenes clone the native frame graph, so source layout and nested scene handles may be released after creation. Upstream caches manage their own references independently. Export buffers and outline snapshots likewise have independent owners. String, byte, diagnostic and outline views borrow their owning handle; they become invalid at its last release. Input arrays and strings generally need to live only until the call returns.

Operations return `TypstStatus` and optional owned diagnostics. `TYPST_OK` may still carry warnings. Ordinary Typst failures, invalid arguments, unsupported content and caught panics have distinct statuses; Rust unwinding does not cross C. Output handle slots are cleared on failure. There is no native global or thread-local last-error slot. A successful batch call means that every request was processed: inspect each `TypstLayoutResult.status` and release each result's layout and diagnostics independently, including mixed failures.

`TypstStr` is a pointer plus UTF-8 byte length; `TypstBytes` is an arbitrary binary view. Null data is valid only at zero length. The library checks text encoding and argument shape; callers must still provide live, aligned memory and respect object lifetimes. Source names use Typst's normalized rooted virtual paths, so `main.typ` may appear as `/main.typ` in diagnostics.

## Compatibility and concurrency

Public option records carry `struct_size`, are passed by pointer, and default missing fields. Unknown trailing fields are ignored. Fixed value/array records and existing constants retain their ABI meanings; upstream enum orders and Rust layouts are not part of the contract. Consumers check the ABI major, minimum minor, required capabilities and symbols before calling.

Contexts share read-only resources, while each job owns its source, native evaluation state and diagnostics. Batched independent layouts use the existing Rayon pool and publish results in request order. Immutable retained results can be read concurrently; release must not race their last use. Upstream comemo caches are reused, and eviction does not invalidate live handles. Cache retention is not a substitute for retaining a layout.

Keep the dynamic library mapped while its objects, workers or thread-local destructors may reference it. The acceptance consumer leaves the mapping resident until process exit while releasing individual handles normally. Compatible replacements are supported between process starts; live library hot-unloading is not provided.

See the [C ABI contract](../docs/abi.md), [upstream API mapping](../docs/rust-api.md), [native scene model](../docs/native-scene.md) and [outline contract](../docs/text-outlines.md).
