//! Stable C data types. These layouts and numeric values belong to libtypst.

mod requests;
mod results;
mod scene;

pub use requests::*;
pub use results::*;
pub use scene::*;
pub type TypstStatus = u32;
pub const TYPST_OK: TypstStatus = 0;
pub const TYPST_INVALID_ARGUMENT: TypstStatus = 1;
pub const TYPST_INVALID_UTF8: TypstStatus = 2;
pub const TYPST_COMPILE_FAILED: TypstStatus = 3;
pub const TYPST_UNSUPPORTED: TypstStatus = 4;
pub const TYPST_PANIC: TypstStatus = 5;
pub const TYPST_OUT_OF_RANGE: TypstStatus = 6;
pub const TYPST_ABI_VERSION: u32 = 0x0001_000C;
pub const TYPST_CAP_PDF: u64 = 1;
pub const TYPST_CAP_BATCH_LAYOUT: u64 = 2;
pub const TYPST_CAP_NATIVE_SCENE: u64 = 4;
pub const TYPST_CAP_TEXT_OUTLINE: u64 = 8;
/// Per-request lexical bindings in content layout options.
pub const TYPST_CAP_LAYOUT_BINDINGS: u64 = 16;
/// Import a PDF page as a retained native scene.
pub const TYPST_CAP_PDF_IMPORT: u64 = 32;
/// Font directories and TYPST_CONTEXT_SYSTEM_FONTS, discovered by typst-kit.
/// Builds without a file system, such as Wasm, do not report it.
pub const TYPST_CAP_FONT_DISCOVERY: u64 = 64;
/// Template functions evaluated from code with their own bindings in content
/// layout options, as binding values and as show rules around the content.
pub const TYPST_CAP_LAYOUT_TEMPLATES: u64 = 128;
/// Labeled elements of a layout, with their positions and extents.
pub const TYPST_CAP_LAYOUT_LABELS: u64 = 256;
/// Module values among layout bindings.
pub const TYPST_CAP_BINDING_MODULES: u64 = 512;
/// `typst_context_eval`, the module handles it returns in layout and
/// evaluation options, and TYPST_VALUE_MODULE_HANDLE inputs.
pub const TYPST_CAP_MODULE_HANDLES: u64 = 1024;
/// Show rules given as values in layout options.
pub const TYPST_CAP_SHOW_VALUES: u64 = 2048;
/// `typst_source_member_uses`.
pub const TYPST_CAP_MEMBER_USES: u64 = 4096;
/// Custom PDF Creator metadata in TypstPdfOptions.
pub const TYPST_CAP_PDF_CREATOR: u64 = 8192;
/// Color stops at given positions, TYPST_GRADIENT_STOP_OFFSETS.
pub const TYPST_CAP_GRADIENT_STOPS: u64 = 16384;
/// `typst_pdf_page_with_opacity`.
pub const TYPST_CAP_PDF_PAGE_OPACITY: u64 = 32768;
/// `typst_scene_from_pixels`.
pub const TYPST_CAP_RASTER_IMAGE: u64 = 65536;
/// Row-major packed 8-bit RGB pixels, three bytes per pixel, top-to-bottom.
pub const TYPST_PIXEL_RGB8: u32 = 0;
/// Row-major packed 8-bit straight-alpha RGBA pixels, four bytes per pixel, top-to-bottom.
pub const TYPST_PIXEL_RGBA8: u32 = 1;
pub const TYPST_VALUE_NONE: u32 = 0;
pub const TYPST_VALUE_BOOL: u32 = 1;
pub const TYPST_VALUE_INT: u32 = 2;
pub const TYPST_VALUE_FLOAT: u32 = 3;
pub const TYPST_VALUE_STRING: u32 = 4;
pub const TYPST_VALUE_ARRAY: u32 = 5;
pub const TYPST_VALUE_DICT: u32 = 6;
/// `number` is an absolute length in points.
pub const TYPST_VALUE_LENGTH: u32 = 7;
pub const TYPST_VALUE_COLOR: u32 = 8;
/// `integer` indexes the layout options' templates; the value is that
/// template's function, for `show:` rules or direct calls.
pub const TYPST_VALUE_TEMPLATE: u32 = 9;
/// A module whose members are `bindings`, named by `text` or anonymous when
/// `text` is empty. Unlike dictionary keys, Typst code calls a module's
/// function members directly, as `lib.f(x)`, in markup and math alike.
pub const TYPST_VALUE_MODULE: u32 = 10;
/// `integer` indexes the options' module handles; the value is the module
/// that handle retains.
pub const TYPST_VALUE_MODULE_HANDLE: u32 = 11;
/// The source binds the queried name itself, for example with `let` or as a
/// parameter, so some reported uses may not refer to the outer value.
pub const TYPST_MEMBER_USES_REBOUND: u32 = 1;
/// The source also uses the queried name as a whole value: it occurs other
/// than as the owner of a reported member and other than where the source
/// binds it, as in `f(name)`, `#name` or `import name: *`.
pub const TYPST_MEMBER_USES_WHOLE: u32 = 2;
pub const TYPST_CONTEXT_NO_BUILTIN_FONTS: u32 = 1;
pub const TYPST_CONTEXT_DISABLE_PLUGINS: u32 = 2;
/// Add the fonts installed on the system, as found by typst-kit. Requires
/// TYPST_CAP_FONT_DISCOVERY; they are read when first used.
pub const TYPST_CONTEXT_SYSTEM_FONTS: u32 = 4;
pub const TYPST_SYNTAX_MARKUP: u32 = 0;
pub const TYPST_SYNTAX_CODE: u32 = 1;
pub const TYPST_SYNTAX_MATH: u32 = 2;
pub const TYPST_EXPAND_X: u32 = 1;
pub const TYPST_EXPAND_Y: u32 = 2;
/// Marks an explicitly bounded dimension, including a finite zero-point region.
pub const TYPST_BOUND_X: u32 = 4;
pub const TYPST_BOUND_Y: u32 = 8;
pub const TYPST_DIAGNOSTIC_ERROR: u32 = 1;
pub const TYPST_DIAGNOSTIC_WARNING: u32 = 2;
pub const TYPST_DIAGNOSTIC_NOTE: u32 = 3;
pub const TYPST_DIAGNOSTIC_HAS_RANGE: u32 = 1;
pub const TYPST_DIAGNOSTIC_HINT: u32 = 2;
pub const TYPST_DIAGNOSTIC_TRACE: u32 = 4;
pub const TYPST_SEGMENT_MOVE: u32 = 0;
pub const TYPST_SEGMENT_LINE: u32 = 1;
pub const TYPST_SEGMENT_CUBIC: u32 = 2;
pub const TYPST_SEGMENT_CLOSE: u32 = 3;
pub const TYPST_STYLE_FILL: u32 = 1;
pub const TYPST_STYLE_STROKE: u32 = 2;
pub const TYPST_FILL_NONZERO: u32 = 0;
pub const TYPST_FILL_EVENODD: u32 = 1;
pub const TYPST_CAP_BUTT: u32 = 0;
pub const TYPST_CAP_ROUND: u32 = 1;
pub const TYPST_CAP_SQUARE: u32 = 2;
pub const TYPST_JOIN_MITER: u32 = 0;
pub const TYPST_JOIN_ROUND: u32 = 1;
pub const TYPST_JOIN_BEVEL: u32 = 2;
pub const TYPST_ITEM_PATH: u32 = 0;
pub const TYPST_ITEM_LAYOUT: u32 = 1;
pub const TYPST_ITEM_SCENE: u32 = 2;
pub const TYPST_OUTLINE_GLYPH: u32 = 0;
pub const TYPST_OUTLINE_SHAPE: u32 = 1;
/// A clipping scope in the ordered outline stream. Its path and transform
/// describe a nonzero-rule clip in layout coordinates; paints are unused.
pub const TYPST_OUTLINE_BEGIN_CLIP: u32 = 2;
/// Closes the most recent clipping scope. Geometry and paints are unused.
pub const TYPST_OUTLINE_END_CLIP: u32 = 3;
pub const TYPST_SCENE_ITEM_ISOLATE_TRANSFORM: u32 = 1;
/// The labeled element's `min` and `max` hold its extent. Without it, the
/// element lays out nothing, such as labeled metadata.
pub const TYPST_LABEL_EXTENT: u32 = 1;

/// A borrowed UTF-8 view; the pointer may be NULL only when len is zero.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TypstStr {
    pub data: *const u8,
    pub len: usize,
}
impl Default for TypstStr {
    fn default() -> Self {
        Self {
            data: std::ptr::null(),
            len: 0,
        }
    }
}
impl TypstStr {
    pub(crate) fn view(value: &str) -> Self {
        Self {
            data: value.as_ptr(),
            len: value.len(),
        }
    }
}
/// A borrowed binary view with the same null/length rule as TypstStr.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TypstBytes {
    pub data: *const u8,
    pub len: usize,
}
impl Default for TypstBytes {
    fn default() -> Self {
        Self {
            data: std::ptr::null(),
            len: 0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TypstMetrics {
    pub width_pt: f64,
    pub height_pt: f64,
    pub baseline_pt: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TypstPoint {
    pub x: f64,
    pub y: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TypstTransform {
    pub xx: f64,
    pub yx: f64,
    pub xy: f64,
    pub yy: f64,
    pub dx: f64,
    pub dy: f64,
}
impl Default for TypstTransform {
    fn default() -> Self {
        Self {
            xx: 1.0,
            yx: 0.0,
            xy: 0.0,
            yy: 1.0,
            dx: 0.0,
            dy: 0.0,
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TypstColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstPdfOptions {
    pub struct_size: u32,
    pub flags: u32,
    pub standard: TypstStr,
    /// Borrowed UTF-8 application name, written to PDF Creator and XMP
    /// CreatorTool. Empty or omitted selects Typst's default, including its
    /// version. Requires TYPST_CAP_PDF_CREATOR.
    pub creator: TypstStr,
}
impl Default for TypstPdfOptions {
    fn default() -> Self {
        Self {
            struct_size: std::mem::size_of::<Self>() as u32,
            flags: 0,
            standard: TypstStr::default(),
            creator: TypstStr::default(),
        }
    }
}
