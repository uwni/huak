//! Records the library hands out as borrowed views.
use super::*;

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
