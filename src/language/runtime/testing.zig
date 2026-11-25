//! Helpers shared by the runtime tests.
const Runtime = @import("../Runtime.zig");
const types = @import("../types.zig");

pub fn testOwner(value: types.Value) *Runtime.SceneOwner {
    return @ptrCast(@alignCast(@constCast(value.object.owner)));
}
