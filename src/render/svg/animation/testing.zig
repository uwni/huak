//! The SMIL encoder call and the fixture SVG shared by the animation tests.
const std = @import("std");
const a = @import("../../../animation/root.zig");
const t = std.testing;
const svg_animation = @import("../animation.zig");
const encodeAnimatedSvg = svg_animation.encodeAnimatedSvg;

/// Encodes with every track marked `smil`, checking the SMIL elements alone.
/// The copy uses the testing allocator, not the one under test.
pub fn encodeSmil(allocator: std.mem.Allocator, static_svg: []const u8, animation: *const a.Animation) ![]u8 {
    const tracks = try t.allocator.dupe(a.Track, animation.tracks);
    defer t.allocator.free(tracks);
    for (tracks) |*track| track.smil = true;
    var marked = animation.*;
    marked.tracks = tracks;
    return encodeAnimatedSvg(allocator, static_svg, &marked);
}

pub const fixture = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100' viewBox='0 0 100 100'><defs><path id='glyph' d='M0 0L1 1'/></defs><g data-typst-label='libtypst-object-7' transform='translate(5 6)'><path fill='red' d='M0 0L10 0Z'/></g><g data-typst-label='libtypst-object-9'><use href='#glyph'/></g></svg>";
