//! Immutable scene export. Language state, scheduling and filesystem I/O belong
//! to callers; every invocation owns its native document and result buffer.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../drawing/geometry.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const animation = @import("../animation/root.zig");
const Workers = @import("workers");
const backend = @import("typst/scene.zig");
const svg = @import("svg/animation.zig");
const svg_mesh = @import("svg/mesh.zig");
const svg_styles = @import("svg/styles.zig");

pub const FrameBounds = backend.FrameBounds;

pub fn bounds(picture: *const DisplayList, frames: []const typst.FrameRef) !?g.BBox {
    return picture.boundsWith(FrameBounds{ .frames = frames });
}

pub const viewport = backend.viewport;

pub const strokeFootprint = @import("typst/pen.zig").strokeFootprint;

pub const Format = enum {
    svg,
    pdf,

    /// Meshes need no check here: SVG reports a mesh it cannot draw as the
    /// encoder reaches it.
    pub fn validate(self: Format, animated: bool) !void {
        if (animated and self == .pdf) return error.AnimationRequiresSvg;
    }
};

pub fn usesMesh(command: *const DisplayList.Command) bool {
    if (command.* != .path) return false;
    for ([_]DisplayList.Style.Component{ .fill, .stroke }) |component| {
        if (command.path.style.gradientFor(component)) |gradient| if (gradient.isMesh()) return true;
    }
    return false;
}

/// Matching allocation owners stay with the bytes and never cross the ABI.
pub const Output = union(enum) {
    native: typst.Buffer,
    /// SVG that huak completed after Typst's export, with animations or the
    /// mesh stylesheet.
    edited: struct { allocator: std.mem.Allocator, data: []u8 },

    pub fn bytes(self: *const Output) []const u8 {
        return switch (self.*) {
            .native => |*buffer| buffer.bytes(),
            .edited => |buffer| buffer.data,
        };
    }

    pub fn deinit(self: *Output) void {
        switch (self.*) {
            .native => |*buffer| buffer.deinit(),
            .edited => |buffer| buffer.allocator.free(buffer.data),
        }
        self.* = undefined;
    }
};

/// Borrowed read-only inputs. Retained layouts and the library must remain alive
/// until render returns. Concurrent calls use independent scratch allocators.
pub const Scene = struct {
    picture: *const DisplayList,
    /// An omitted size fits the page to its ink during submission.
    size: ?g.Point = null,
    origin: g.Point = .zero,
    frames: []const typst.FrameRef = &.{},
    object_ids: ?[]const u64 = null,
    tracks: ?animation.Animation = null,
    workers: Workers = .serial,

    pub fn validate(self: Scene, format: Format) !void {
        return format.validate(self.tracks != null);
    }

    /// diagnostic must initially own nothing. Preserve the host's presentation
    /// of the per-call native diagnostic before returning. The caller owns the
    /// copied Buffer, including on failure.
    pub fn render(self: Scene, allocator: std.mem.Allocator, library: *typst.Library, format: Format, diagnostic: *?typst.Buffer) !Output {
        try self.validate(format);
        var document = backend.submitPicture(allocator, library, self.picture, self.size, .{
            .origin = self.origin,
            .frames = self.frames,
            .object_ids = self.object_ids,
            .pdf = format == .pdf,
            .workers = self.workers,
        }) catch |err| {
            diagnostic.* = library.lastError() catch null;
            return err;
        };
        defer document.deinit();
        var buffer = switch (format) {
            .svg => document.exportSvg(0),
            .pdf => exportPdf(allocator, &document),
        } catch |err| {
            diagnostic.* = library.lastError() catch null;
            return err;
        };
        // Rules for what Typst's scene cannot say: see svg/styles.zig.
        var rules: std.ArrayList(u8) = .empty;
        defer rules.deinit(allocator);
        if (format == .svg) {
            var meshes = false;
            for (self.picture.commands.items) |*command| switch (command.*) {
                .path => meshes = meshes or usesMesh(command),
                .push => |scope| if (scope.opacity < 1) try svg_styles.layerRule(&rules, allocator, scope.opacity),
                else => {},
            };
            if (meshes) try rules.appendSlice(allocator, svg_mesh.rule);
        }
        if (self.tracks == null and rules.items.len == 0) return .{ .native = buffer };
        defer buffer.deinit();
        const animated: ?[]u8 = if (self.tracks) |tracks| try svg.encodeAnimatedSvg(allocator, buffer.bytes(), &tracks) else null;
        if (rules.items.len == 0) return .{ .edited = .{ .allocator = allocator, .data = animated.? } };
        defer if (animated) |bytes| allocator.free(bytes);
        return .{ .edited = .{ .allocator = allocator, .data = try svg_styles.add(allocator, animated orelse buffer.bytes(), rules.items) } };
    }
};

/// Export a prepared huak document with the host and loaded backend versions.
pub fn exportPdf(allocator: std.mem.Allocator, document: *const typst.Document) !typst.Buffer {
    const creator = try std.fmt.allocPrint(allocator, "huak {s} (Typst {s})", .{
        @import("build_options").version,
        try document.library.typstVersion(),
    });
    defer allocator.free(creator);
    return document.exportPdfWithOptions(.{ .creator = creator });
}
