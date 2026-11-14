//! Stable C data types. These layouts and numeric values belong to libtypst.
pub type TypstStatus = u32;
pub const TYPST_OK: TypstStatus = 0;
pub const TYPST_INVALID_ARGUMENT: TypstStatus = 1;
pub const TYPST_INVALID_UTF8: TypstStatus = 2;
pub const TYPST_COMPILE_FAILED: TypstStatus = 3;
pub const TYPST_UNSUPPORTED: TypstStatus = 4;
pub const TYPST_PANIC: TypstStatus = 5;
pub const TYPST_OUT_OF_RANGE: TypstStatus = 6;
pub const TYPST_ABI_VERSION: u32 = 0x0001_0009;
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
#[derive(Clone, Copy)]
pub struct TypstFontSource {
    pub data: TypstBytes,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstFile {
    pub path: TypstStr,
    pub data: TypstBytes,
}

/// Pass by pointer. Zero/null fields request defaults. Unknown trailing fields
/// are ignored; this library reads no more than struct_size bytes.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstContextOptions {
    pub struct_size: u32,
    pub flags: u32,
    pub fonts: *const TypstFontSource,
    pub font_count: usize,
    pub files: *const TypstFile,
    pub file_count: usize,
    /// JSON object made available as Typst sys.inputs, using upstream decoding.
    pub inputs_json: TypstStr,
    /// Directories that typst-kit scans recursively for fonts. Fonts are read
    /// when first used. Requires TYPST_CAP_FONT_DISCOVERY.
    pub font_dirs: *const TypstStr,
    pub font_dir_count: usize,
}
impl Default for TypstContextOptions {
    fn default() -> Self {
        Self {
            struct_size: std::mem::size_of::<Self>() as u32,
            flags: 0,
            fonts: std::ptr::null(),
            font_count: 0,
            files: std::ptr::null(),
            file_count: 0,
            inputs_json: TypstStr::default(),
            font_dirs: std::ptr::null(),
            font_dir_count: 0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstLayoutOptions {
    pub struct_size: u32,
    /// TYPST_EXPAND_X/Y and TYPST_BOUND_X/Y. Expansion requires a bounded,
    /// finite, nonnegative dimension; zero also requires its BOUND flag.
    pub flags: u32,
    /// Sizes are in points. Zero is unbounded unless its BOUND flag is set.
    pub width_pt: f64,
    pub height_pt: f64,
    pub syntax: u32,
    pub reserved: u32,
    /// Independent Typst setup code evaluated in the same native lexical scope
    /// before the body. Trees retain separate source names and byte ranges.
    pub setup_code: TypstStr,
    pub setup_source_name: TypstStr,
    /// Borrowed values become request-local native Typst bindings. The library
    /// copies their data during the call; context/import scopes are unaffected.
    pub bindings: *const TypstBinding,
    pub binding_count: usize,
    /// Borrowed templates. TYPST_VALUE_TEMPLATE inputs in `bindings` refer to
    /// them by index. Requires TYPST_CAP_LAYOUT_TEMPLATES.
    pub templates: *const TypstTemplate,
    pub template_count: usize,
    /// Template indices applied to the request's content like `#show:` rules
    /// at its start, outermost first. Rules nearer the content take precedence.
    pub shows: *const usize,
    pub show_count: usize,
    /// Borrowed modules that `typst_context_eval` made. The request's values
    /// and templates refer to them by index with TYPST_VALUE_MODULE_HANDLE.
    /// Requires TYPST_CAP_MODULE_HANDLES.
    pub module_handles: *const *const crate::handles::TypstModule,
    pub module_handle_count: usize,
    /// Show rules given as values, applied inside `shows`, outermost first.
    /// Requires TYPST_CAP_SHOW_VALUES.
    pub show_values: *const TypstShowValue,
    pub show_value_count: usize,
}

/// Pass by pointer; null selects defaults. `bindings` are names visible to the
/// evaluated source from an enclosing scope; they are not members of the
/// module. TYPST_VALUE_MODULE_HANDLE inputs among them index `module_handles`;
/// template inputs have nothing to refer to here.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstEvalOptions {
    pub struct_size: u32,
    /// No flags are defined; must be zero.
    pub flags: u32,
    pub bindings: *const TypstBinding,
    pub binding_count: usize,
    pub module_handles: *const *const crate::handles::TypstModule,
    pub module_handle_count: usize,
}
impl Default for TypstEvalOptions {
    fn default() -> Self {
        Self {
            struct_size: std::mem::size_of::<Self>() as u32,
            flags: 0,
            bindings: std::ptr::null(),
            binding_count: 0,
            module_handles: std::ptr::null(),
            module_handle_count: 0,
        }
    }
}

/// A show rule given as a value, converted like a binding value. Each path
/// entry names a field read from the value in turn, as `value.a.b` would; the
/// result must be a function. Frozen array element layout.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstShowValue {
    pub value: *const TypstValueInput,
    pub path: *const TypstStr,
    pub path_count: usize,
}

/// Independent Typst code whose value is a function, such as
/// `body => { set text(red); body }`, evaluated once per request in its own
/// scope with its own borrowed bindings. Optional setup code runs first in
/// that scope, so the function can use its definitions; the setup's own set
/// and show rules style nothing. TYPST_VALUE_TEMPLATE inputs in a template's
/// own bindings may refer only to earlier templates in the same array.
/// Source names must differ from the request's and from each other.
/// Frozen array element layout.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstTemplate {
    pub code: TypstStr,
    pub source_name: TypstStr,
    pub setup_code: TypstStr,
    pub setup_source_name: TypstStr,
    pub bindings: *const TypstBinding,
    pub binding_count: usize,
}
impl Default for TypstLayoutOptions {
    fn default() -> Self {
        Self {
            struct_size: std::mem::size_of::<Self>() as u32,
            flags: 0,
            width_pt: 0.0,
            height_pt: 0.0,
            syntax: TYPST_SYNTAX_MARKUP,
            reserved: 0,
            setup_code: TypstStr::default(),
            setup_source_name: TypstStr::default(),
            bindings: std::ptr::null(),
            binding_count: 0,
            templates: std::ptr::null(),
            template_count: 0,
            shows: std::ptr::null(),
            show_count: 0,
            module_handles: std::ptr::null(),
            module_handle_count: 0,
            show_values: std::ptr::null(),
            show_value_count: 0,
        }
    }
}
/// Frozen array element layout. Extend the pointed-to options, not this record.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstLayoutRequest {
    pub source: TypstStr,
    pub source_name: TypstStr,
    pub options: *const TypstLayoutOptions,
}

/// Each completed batch request owns its layout (on success) and optional
/// diagnostics. Release both handles independently, including on partial error.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstLayoutResult {
    pub status: TypstStatus,
    pub reserved: u32,
    pub layout: *mut crate::handles::TypstLayout,
    pub diagnostics: *mut crate::handles::TypstDiagnostics,
}
impl Default for TypstLayoutResult {
    fn default() -> Self {
        Self {
            status: TYPST_INVALID_ARGUMENT,
            reserved: 0,
            layout: std::ptr::null_mut(),
            diagnostics: std::ptr::null_mut(),
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

/// A borrowed named value. Record layouts are fixed for this ABI series.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstBinding {
    pub name: TypstStr,
    pub value: *const TypstValueInput,
}

/// Borrowed native-value input. Only the fields selected by `kind` are read:
/// BOOL/INT/TEMPLATE/MODULE_HANDLE use `integer`, FLOAT/LENGTH
/// use `number`, STRING uses `text`, COLOR uses `color`, ARRAY uses
/// `items/item_count`, DICT uses `bindings/binding_count`, and MODULE uses
/// `text` with `bindings/binding_count`.
/// `reserved` must be zero. Nested inputs are limited to depth 64 and one
/// million nodes per request. These are C contract kinds, not Rust enum values.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstValueInput {
    pub kind: u32,
    pub reserved: u32,
    pub integer: i64,
    pub number: f64,
    pub text: TypstStr,
    pub color: TypstColor,
    pub items: *const TypstValueInput,
    pub item_count: usize,
    pub bindings: *const TypstBinding,
    pub binding_count: usize,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TypstPathSegment {
    pub kind: u32,
    pub reserved: u32,
    pub p1: TypstPoint,
    pub p2: TypstPoint,
    pub p3: TypstPoint,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstPath {
    pub segments: *const TypstPathSegment,
    pub segment_count: usize,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstStyle {
    pub flags: u32,
    pub fill_rule: u32,
    pub fill: TypstColor,
    pub stroke: TypstColor,
    pub stroke_width_pt: f64,
    pub line_cap: u32,
    pub line_join: u32,
    pub miter_limit: f64,
    pub dashes: *const f64,
    pub dash_count: usize,
    pub dash_phase_pt: f64,
}
/// Each item selects exactly one path, layout or nested scene. clip is optional.
/// All input views are borrowed only for scene creation. The resulting scene
/// retains referenced layouts/scenes and can outlive their original owners.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstSceneItem {
    pub kind: u32,
    pub reserved: u32,
    pub transform: TypstTransform,
    pub path: *const TypstPath,
    pub style: *const TypstStyle,
    pub layout: *const crate::handles::TypstLayout,
    pub scene: *const crate::handles::TypstScene,
    pub clip: *const TypstPath,
    pub options: *const TypstSceneItemOptions,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstGradient {
    /// TYPST_GRADIENT_LINEAR or TYPST_GRADIENT_RADIAL.
    pub kind: u32,
    pub reserved: u32,
    /// Endpoints of the linear ramp or center and rim of the radial ramp, in local points.
    pub start: TypstPoint,
    pub end: TypstPoint,
    /// Equally spaced color stops, including both endpoints.
    pub colors: *const TypstColor,
    pub count: usize,
}
pub const TYPST_GRADIENT_LINEAR: u32 = 0;
pub const TYPST_GRADIENT_RADIAL: u32 = 1;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstSceneItemOptions {
    pub struct_size: u32,
    pub flags: u32,
    /// Optional metadata label retained in native SVG output.
    pub tag: TypstStr,
    /// Optional paints on a filled or stroked path. Borrowed for scene creation.
    pub fill_gradient: *const TypstGradient,
    pub stroke_gradient: *const TypstGradient,
}
impl Default for TypstSceneItemOptions {
    fn default() -> Self {
        Self {
            struct_size: std::mem::size_of::<Self>() as u32,
            flags: 0,
            tag: TypstStr::default(),
            fill_gradient: std::ptr::null(),
            stroke_gradient: std::ptr::null(),
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstSceneOptions {
    pub struct_size: u32,
    pub flags: u32,
    pub width_pt: f64,
    pub height_pt: f64,
    pub items: *const TypstSceneItem,
    pub item_count: usize,
}
impl Default for TypstSceneOptions {
    fn default() -> Self {
        Self {
            struct_size: std::mem::size_of::<Self>() as u32,
            flags: 0,
            width_pt: 0.0,
            height_pt: 0.0,
            items: std::ptr::null(),
            item_count: 0,
        }
    }
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
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TypstDiagnosticView {
    pub severity: u32,
    pub flags: u32,
    pub message: TypstStr,
    pub source_name: TypstStr,
    pub byte_start: usize,
    pub byte_end: usize,
    /// SIZE_MAX denotes a request-independent diagnostic.
    pub request_index: usize,
    pub note_count: usize,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TypstOutlinedPath {
    pub segment_offset: usize,
    pub segment_count: usize,
    /// Maps local point coordinates into the layout coordinate system. Keeping
    /// this transform preserves nonuniformly transformed native strokes.
    pub transform: TypstTransform,
    pub flags: u32,
    pub fill_rule: u32,
    pub fill: TypstColor,
    pub stroke: TypstColor,
    pub stroke_width_pt: f64,
    pub line_cap: u32,
    pub line_join: u32,
    pub miter_limit: f64,
    pub dash_offset: usize,
    pub dash_count: usize,
    pub dash_phase_pt: f64,
    /// Glyph records include whitespace with zero segments and a real advance.
    /// BEGIN_CLIP/END_CLIP bracket paths in native paint order. Clips nest;
    /// their transforms are absolute, just like glyph/shape transforms.
    pub kind: u32,
    pub glyph_id: u32,
    pub run_index: usize,
    pub run_text: TypstStr,
    pub cluster_start: usize,
    pub cluster_end: usize,
    /// Advance vector in the layout's y-down point coordinates.
    pub advance: TypstPoint,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstOutlineView {
    pub paths: *const TypstOutlinedPath,
    pub path_count: usize,
    pub segments: *const TypstPathSegment,
    pub segment_count: usize,
    pub dashes: *const f64,
    pub dash_count: usize,
    pub run_count: usize,
}
/// An element that carries a label, in the layout's y-down points.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TypstLabeledElement {
    /// The label's name, without angle brackets.
    pub label: TypstStr,
    /// Where the element starts: the position Typst's `location.position()`
    /// reports in a document. Inline and math content start on their baseline;
    /// an element that begins a paragraph starts at the paragraph's top left.
    pub position: TypstPoint,
    /// Conservative extent with TYPST_LABEL_EXTENT: the logical rectangle of
    /// each frame the element lays out and what its content paints, like
    /// `typst_layout_bounds`. Clips may make the visible extent smaller.
    pub min: TypstPoint,
    pub max: TypstPoint,
    pub flags: u32,
}
/// One place where Typst code reads a member of a name: the identifier
/// `member` in `name.member` or in `import name: member`. `start` and `end`
/// are its byte range in the queried source.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstMemberUse {
    pub member: TypstStr,
    pub start: usize,
    pub end: usize,
}
/// Borrows the uses found by `typst_source_member_uses`, in source order.
/// `flags` may contain TYPST_MEMBER_USES_REBOUND and TYPST_MEMBER_USES_WHOLE.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstMemberUseView {
    pub uses: *const TypstMemberUse,
    pub use_count: usize,
    pub flags: u32,
    pub reserved: u32,
}
impl Default for TypstMemberUseView {
    fn default() -> Self {
        Self {
            uses: std::ptr::null(),
            use_count: 0,
            flags: 0,
            reserved: 0,
        }
    }
}
/// Borrows a layout's labeled elements, in document order.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TypstLabelView {
    pub elements: *const TypstLabeledElement,
    pub element_count: usize,
}
impl Default for TypstLabelView {
    fn default() -> Self {
        Self {
            elements: std::ptr::null(),
            element_count: 0,
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct TypstVersionInfo {
    pub abi_major: u32,
    pub abi_minor: u32,
    pub capabilities: u64,
    pub library_version: TypstStr,
    pub typst_version: TypstStr,
}
