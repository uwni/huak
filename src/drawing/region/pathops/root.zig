//! Skia-derived binary64 curve queries used by path crossings and regression probes.
//! Source provenance, numeric policies and ownership are documented in README.md.
pub const numeric = @import("numeric.zig");
pub const point = @import("point.zig");
pub const roots = @import("roots.zig");
pub const curve = @import("curve.zig");
pub const Intersections = @import("Intersections.zig");
pub const winding = @import("winding.zig");
pub const reduce = @import("reduce.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
