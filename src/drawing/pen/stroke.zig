//! Stroke choices shared by native strokes and computed convex-nib outlines.
pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };
/// A stroke's ends and corners unless it says otherwise, as SVG's initial
/// values.
pub const default_cap: Cap = .butt;
pub const default_join: Join = .miter;
pub const default_miter_limit = 4;
