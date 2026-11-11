//! Rendering-independent mathematical drawing core. No dynamic library needed.
pub const geometry = @import("geometry.zig");
pub const Path = @import("path/Path.zig");
pub const path_construct = @import("path/construct.zig");
pub const path_fillet = @import("path/fillet.zig");
pub const Measure = @import("path/Measure.zig");
pub const transform = @import("transform/root.zig");
pub const crossings = @import("path/crossings.zig");
pub const region = @import("region/root.zig");
pub const solver = @import("solver.zig");
pub const hobby = @import("path/hobby.zig");
pub const DisplayList = @import("DisplayList.zig");
pub const Scene = @import("Scene.zig");
pub const outline = @import("outline.zig");
pub const units = @import("units.zig");
pub const pen = @import("pen/root.zig");
pub const simd = @import("simd.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
