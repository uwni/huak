//! Native affine and nonlinear geometry transformations.
pub const Bend = @import("Bend.zig");
pub const mapping = @import("map.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
