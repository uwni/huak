//! Immutable scene export. Language state, scheduling and filesystem I/O belong
//! to callers; every invocation owns its native document and result buffer.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../drawing/geometry.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const animation = @import("../animation/root.zig");
const backend = @import("typst/root.zig");
const svg = @import("svg/animation.zig");

pub const FrameBounds = struct {
    frames: []const typst.FrameRef,
    pub fn resolveBounds(self: FrameBounds, reference: u32) !g.BBox {
        if (reference >= self.frames.len) return error.InvalidFrameReference;
        const frame = self.frames[reference];
        const box = try frame.layout.bounds(frame.index);
        return .{ .min = .{ .x = box[0].x, .y = box[0].y }, .max = .{ .x = box[1].x, .y = box[1].y } };
    }
};

pub fn bounds(picture: *const DisplayList, frames: []const typst.FrameRef) !?g.BBox {
    return picture.boundsWith(FrameBounds{ .frames = frames });
}

pub fn viewport(picture: *const DisplayList, size: ?g.Point, frames: []const typst.FrameRef) !g.BBox {
    if (size) |value| return .{ .min = .zero, .max = value };
    return (try bounds(picture, frames)) orelse .{ .min = .zero, .max = .zero };
}

pub const motionFootprint = @import("typst/pen.zig").motionFootprint;
pub const strokeFootprint = @import("typst/pen.zig").strokeFootprint;

pub const Format = enum { svg, pdf };

/// Matching allocation owners stay with the bytes and never cross the ABI.
pub const Output = union(enum) {
    native: typst.Buffer,
    animated: struct { allocator: std.mem.Allocator, data: []u8 },

    pub fn bytes(self: *const Output) []const u8 {
        return switch (self.*) {
            .native => |*buffer| buffer.bytes(),
            .animated => |buffer| buffer.data,
        };
    }

    pub fn deinit(self: *Output) void {
        switch (self.*) {
            .native => |*buffer| buffer.deinit(),
            .animated => |buffer| buffer.allocator.free(buffer.data),
        }
        self.* = undefined;
    }
};

/// Borrowed read-only inputs. Retained layouts and the library must remain alive
/// until render returns. Concurrent calls use independent scratch allocators.
pub const Scene = struct {
    picture: *const DisplayList,
    width: f64,
    height: f64,
    origin: g.Point = .zero,
    frames: []const typst.FrameRef = &.{},
    object_ids: ?[]const u64 = null,
    tracks: ?animation.Animation = null,

    pub fn validate(self: Scene, format: Format) !void {
        if (self.tracks != null and format == .pdf) return error.AnimationRequiresSvg;
    }

    /// diagnostic must initially own nothing. Preserve the host's presentation
    /// of the per-call native diagnostic before returning. The caller owns the
    /// copied Buffer, including on failure.
    pub fn render(self: Scene, allocator: std.mem.Allocator, library: *typst.Library, format: Format, diagnostic: *?typst.Buffer) !Output {
        try self.validate(format);
        var document = backend.submit(allocator, library, self.picture, self.width, self.height, .{
            .origin = self.origin,
            .frames = self.frames,
            .object_ids = self.object_ids,
            .pdf_mesh = format == .pdf,
        }) catch |err| {
            diagnostic.* = library.lastError() catch null;
            return err;
        };
        defer document.deinit();
        var buffer = switch (format) {
            .svg => document.exportSvg(0),
            .pdf => document.exportPdf(),
        } catch |err| {
            diagnostic.* = library.lastError() catch null;
            return err;
        };
        if (self.tracks) |tracks| {
            defer buffer.deinit();
            return .{ .animated = .{ .allocator = allocator, .data = try svg.encodeAnimatedSvg(allocator, buffer.bytes(), &tracks) } };
        }
        return .{ .native = buffer };
    }
};
