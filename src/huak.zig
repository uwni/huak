//! Programmatic drawing API. Geometry and animation tracks are independent
//! of the native typesetter; the backend explicitly uses libtypst.
pub const core = @import("drawing/root.zig");
pub const language = @import("language/root.zig");
pub const tooling = @import("tooling.zig");
pub const backend = @import("render/typst/root.zig");
pub const render = @import("render/root.zig");
pub const worker = @import("concurrency/worker.zig");
pub const animation = @import("animation/root.zig");
pub const sampling = @import("animation/sampling.zig");
pub const motion = @import("animation/motion.zig");
pub const text = struct {
    pub const outline = @import("text/outline.zig");
};
pub const svg = struct {
    pub const animation = @import("render/svg/animation.zig");
};

test {
    _ = core;
    _ = backend;
    _ = @import("render/typst/pen.zig");
    _ = render;
    _ = language;
    _ = worker;
    _ = animation;
    _ = sampling;
    _ = motion;
    _ = svg.animation;
}
