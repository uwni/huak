//! Convex, independently transformed pen geometry. Nib coordinates use the
//! same physical unit as the path. The default circle has diameter one.
const std = @import("std");
const Path = @import("../path/Path.zig");
const Pen = @import("../style.zig").Pen;
const Transform = @import("../geometry.zig").Transform;
pub const Motion = @import("Motion.zig");

pub const Nib = @import("nib.zig").Nib;
pub const OwnedNib = @import("nib.zig").OwnedNib;
pub const makePen = @import("nib.zig").makePen;
pub const StrokeOptions = @import("outline.zig").Options;
pub const strokeOutline = @import("outline.zig").strokeOutline;
pub const EnvelopeOptions = @import("envelope.zig").Options;
pub const envelope = @import("envelope.zig").envelope;
pub const dashed = @import("dash.zig").dashed;
pub const sections = @import("sections.zig");
pub const profileOutline = @import("../region/root.zig").profileStroke;
pub fn motionOutline(allocator: std.mem.Allocator, path: Path, pen: *const Pen, options: StrokeOptions) !Path {
    const nib = pen.nib orelse Nib{ .ellipse = .scaling(pen.width, pen.width) };
    return @import("sweep.zig").expand(allocator, path, nib, pen.motion orelse return error.InvalidMotion, options);
}

pub const Representation = enum { outline, normalized_stroke };
pub const Stroke = struct { path: Path, transform: ?Transform = null };

pub fn footprint(allocator: std.mem.Allocator, source: Path, pen: *const Pen, tolerance: ?f64) !Path {
    var options: StrokeOptions = .{};
    if (pen.motion) |motion| options.tolerance = motion.tolerance;
    if (tolerance) |value| options.tolerance = value;
    return (try resolveStroke(allocator, source, pen, options, .outline)).path;
}

/// A normalized ellipse retains its centerline and placement. All other
/// results are closed outlines in the coordinates of the input path.
pub fn resolveStroke(allocator: std.mem.Allocator, source: Path, pen: *const Pen, options: StrokeOptions, representation: Representation) !Stroke {
    if (pen.motion != null) return .{ .path = try motionOutline(allocator, source, pen, options) };
    var geometry = options;
    geometry.cap = pen.cap;
    geometry.join = pen.join;
    geometry.miter_limit = pen.miter_limit;
    var dash = if (pen.dash.len == 0) null else try dashed(allocator, source, pen.dash, pen.dash_phase, geometry);
    defer if (dash) |*value| value.deinit();
    const center = dash orelse source;
    const nib = try pen.fixedNib();
    if (representation == .normalized_stroke) {
        const normalized = nib.normalizePath(allocator, center) catch |err| switch (err) {
            error.NonFinite => null,
            else => return err,
        };
        if (normalized) |path| return .{ .path = path, .transform = nib.ellipse };
    }
    return .{ .path = try strokeOutline(allocator, nib, center, geometry) };
}
pub const Cap = @import("stroke.zig").Cap;
pub const Join = @import("stroke.zig").Join;

test {
    _ = @import("nib.zig");
    _ = @import("outline.zig");
    _ = @import("dash.zig");
    _ = @import("sections.zig");
    _ = @import("sweep.zig");
}
