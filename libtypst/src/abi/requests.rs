//! Records that create contexts, evaluate modules and request layouts.
use super::*;

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
