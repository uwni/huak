//! Paths, paints and scene items.
use super::*;

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
    /// Zero or TYPST_GRADIENT_STOP_OFFSETS.
    pub flags: u32,
    /// Endpoints of the linear ramp or center and rim of the radial ramp, in local points.
    pub start: TypstPoint,
    pub end: TypstPoint,
    /// Color stops, including both endpoints. Equally spaced unless
    /// `offsets` gives their positions.
    pub colors: *const TypstColor,
    pub count: usize,
    /// Read only with TYPST_GRADIENT_STOP_OFFSETS, so records written before
    /// ABI 1.10 may end before it. One position per color, from 0 to 1 in
    /// non-decreasing order. Requires TYPST_CAP_GRADIENT_STOPS.
    pub offsets: *const f64,
}
pub const TYPST_GRADIENT_LINEAR: u32 = 0;
pub const TYPST_GRADIENT_RADIAL: u32 = 1;
pub const TYPST_GRADIENT_STOP_OFFSETS: u32 = 1;
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
