//! Object identities for the scene tests.
const Scene = @import("../Scene.zig");
const Object = Scene.Object;

pub const TestIds = struct {
    scene: *const Scene,
    pub fn identifier(self: @This(), object_: Object) u64 {
        return if (self.scene == object_.scene) @as(u64, object_.index) + 1 else 0;
    }
};
