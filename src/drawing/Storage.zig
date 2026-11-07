//! Geometry and paint ownership shared by retained scenes and draw lists.
const std = @import("std");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");
const style = @import("style.zig");
pub const Color = style.Color;
pub const Cap = style.Cap;
pub const Join = style.Join;
pub const FillRule = style.FillRule;
pub const Pen = style.Pen;
pub const Style = style.Style;
/// Metrics are supplied by a typesetter; baseline is measured from frame top
/// and may lie outside the frame's height.
pub const Metrics = struct { width: f64, height: f64, baseline: f64 };
/// Source zero is this picture's owned geometry. Other sources borrow the
/// corresponding segment bank for the lifetime of the immutable picture view.
pub const PathRef = struct { first: usize, count: usize, source: u32 = 0, knot_table: u32 = 0 };
pub const Bank = struct { segments: []const Path.Segment = &.{}, blocks: []const KnotBlock = &.{} };
/// The same source selects both the segments and the directory of immutable
/// knot tables. A table ID is local to its bank; zero is an unannotated path.
pub const Geometry = struct {
    primary: Bank = .{},
    sources: []const Bank = &.{},
    fn bank(self: Geometry, index: u32) Error!Bank {
        if (index == 0) return self.primary;
        if (index > self.sources.len) return error.InvalidPath;
        return self.sources[index - 1];
    }
    pub fn source(self: Geometry, index: u32) Error![]const Path.Segment {
        return (try self.bank(index)).segments;
    }
    pub fn range(self: Geometry, ref: PathRef) Error![]const Path.Segment {
        const segments = try self.source(ref.source);
        if (ref.first > segments.len or ref.count > segments.len - ref.first) return error.InvalidPath;
        return segments[ref.first..][0..ref.count];
    }
    fn table(self: Geometry, ref: PathRef) Error!?*const Path.KnotTable {
        if (ref.knot_table == 0) return null;
        const blocks = (try self.bank(ref.source)).blocks;
        if (ref.knot_table > blocks.len) return error.InvalidPath;
        return &blocks[ref.knot_table - 1].table;
    }
    /// Read-only path. Its bank owns both arrays until mutation or release.
    pub fn view(self: Geometry, a: std.mem.Allocator, ref: PathRef) Error!Path {
        var path_ = Path.init(a);
        path_.segments.items = @constCast(try self.range(ref));
        path_.knots = @constCast(try self.table(ref));
        return path_;
    }
};
pub const PathCommand = struct { path: PathRef, style: *const Style, transform: g.Transform };

pub const Label = struct { reference: u32, metrics: Metrics, transform: g.Transform };
pub const Scope = struct { transform: g.Transform, clip: ?PathRef };
pub const Error = std.mem.Allocator.Error || error{
    InvalidColor,
    InvalidPen,
    InvalidMotion,
    InvalidStyle,
    InvalidMetrics,
    InvalidPath,
    NonFinite,
    UnbalancedGroups,
    GroupNestingTooDeep,
    SelfAppend,
    ZeroVector,
};

const Storage = @This();
const KnotBlock = struct { after: usize, table: Path.KnotTable };

allocator: std.mem.Allocator,
styles: style.Pool,
segments: std.ArrayList(Path.Segment) = .empty,
knot_blocks: std.ArrayList(KnotBlock) = .empty,
knot_bytes: usize = 0,

pub fn init(allocator: std.mem.Allocator) Storage {
    return .{ .allocator = allocator, .styles = .init(allocator) };
}
pub fn deinit(self: *Storage) void {
    self.truncateGeometry(0);
    self.knot_blocks.deinit(self.allocator);
    self.segments.deinit(self.allocator);
    self.styles.deinit();
    self.* = undefined;
}
pub fn knotBytes(self: *const Storage) usize {
    return self.knot_bytes + self.knot_blocks.capacity * @sizeOf(KnotBlock);
}
pub fn truncateGeometry(self: *Storage, count: usize) void {
    while (self.knot_blocks.getLastOrNull()) |block| {
        if (block.after <= count) break;
        _ = self.knot_blocks.pop();
        self.knot_bytes -= block.table.entries.items.len * @sizeOf(Path.KnotTable.Knot);
        var table = block.table;
        table.entries.deinit(self.allocator);
    }
    self.segments.items.len = count;
}
fn copyKnots(self: *Storage, src: ?*const Path.KnotTable) Error!u32 {
    const table = (src orelse return 0).*;
    if (table.entries.items.len == 0) return 0;
    if (self.knot_blocks.items.len >= std.math.maxInt(u32)) return error.InvalidPath;
    try self.knot_blocks.ensureUnusedCapacity(self.allocator, 1);
    self.knot_blocks.appendAssumeCapacity(.{ .after = self.segments.items.len, .table = try table.clone(self.allocator) });
    self.knot_bytes += table.entries.items.len * @sizeOf(Path.KnotTable.Knot);
    return @intCast(self.knot_blocks.items.len);
}
pub fn bank(self: *const Storage) Bank {
    return .{ .segments = self.segments.items, .blocks = self.knot_blocks.items };
}
pub fn asGeometry(self: *const Storage) Geometry {
    return .{ .primary = self.bank() };
}
/// A snapshot borrows its primary geometry as one unit, just like other banks.
pub fn borrowBank(self: *Storage, src: *const Storage) void {
    self.segments = src.segments;
    self.knot_blocks = src.knot_blocks;
}
pub fn range(self: *const Storage, reference: PathRef) Error![]const Path.Segment {
    return self.asGeometry().range(reference);
}

/// Callers validate inputs and reserve their node/command first.
pub fn path(self: *Storage, value: *const Path, style_value: *const Style, transform: g.Transform) Error!PathCommand {
    const paint = try self.styles.intern(style_value);
    errdefer self.styles.release(paint);
    var reference = try self.addSegments(value.segments.items);
    errdefer self.truncateGeometry(reference.first);
    reference.knot_table = try self.copyKnots(value.knots);
    return .{ .path = reference, .style = paint, .transform = transform };
}
/// Inputs have passed validateScope; the caller has reserved its node/command.
pub fn scope(self: *Storage, transform: g.Transform, clip: ?*const Path) Error!Scope {
    return .{ .transform = transform, .clip = if (clip) |value| try self.addSegments(value.segments.items) else null };
}
fn addSegments(self: *Storage, value: []const Path.Segment) Error!PathRef {
    const result: PathRef = .{ .first = self.segments.items.len, .count = value.len };
    try self.segments.appendSlice(self.allocator, value);
    return result;
}
/// The caller has validated ranges and reserved the combined segment count.
pub fn copyRange(self: *Storage, geometry: Geometry, reference: PathRef) PathRef {
    const result: PathRef = .{ .first = self.segments.items.len, .count = reference.count };
    self.segments.appendSliceAssumeCapacity(geometry.range(reference) catch unreachable);
    return result;
}
/// same_storage requires a command already owned by self. Its immutable
/// knot block predates the new segment range and survives clone rollback.
pub fn copyPath(self: *Storage, geometry: Geometry, value: PathCommand, ownership: enum { independent, same_storage }) Error!PathCommand {
    var result = value;
    result.path = self.copyRange(geometry, result.path);
    errdefer self.truncateGeometry(result.path.first);
    result.style = try self.styles.intern(result.style);
    errdefer self.styles.release(result.style);
    result.path.knot_table = if (ownership == .same_storage) value.path.knot_table else try self.copyKnots(try geometry.table(value.path));
    return result;
}
pub fn copyScope(self: *Storage, geometry: Geometry, value: Scope) Scope {
    var result = value;
    if (result.clip) |clip| result.clip = self.copyRange(geometry, clip);
    return result;
}

pub fn validateDrawing(path_value: *const Path, style_value: *const Style, transform: g.Transform) Error!void {
    try validateStyle(style_value);
    if (!transform.isFinite()) return error.NonFinite;
    try validatePath(path_value.segments.items, false);
}
pub fn validateScope(transform: g.Transform, clip: ?*const Path) Error!void {
    if (!transform.isFinite()) return error.NonFinite;
    if (clip) |value| try validatePath(value.segments.items, true);
}
pub fn label(reference: u32, metrics: Metrics, transform: g.Transform) Error!Label {
    try validateMetrics(metrics);
    if (!transform.isFinite()) return error.NonFinite;
    return .{ .reference = reference, .metrics = metrics, .transform = transform };
}
pub fn baseline(reference: u32, metrics: Metrics, at: g.Point, transform: g.Transform) Error!Label {
    if (!at.isFinite()) return error.NonFinite;
    const frame_to_world = g.Transform{ .d = -1, .e = at.x, .f = at.y + metrics.baseline };
    return label(reference, metrics, frame_to_world.then(transform));
}
pub fn validateMetrics(metrics: Metrics) Error!void {
    if (!std.math.isFinite(metrics.width) or !std.math.isFinite(metrics.height) or !std.math.isFinite(metrics.baseline)) return error.NonFinite;
    if (metrics.width < 0 or metrics.height < 0) return error.InvalidMetrics;
}
pub fn validateStyle(style_value: *const Style) Error!void {
    if (style_value.fill == null and style_value.pen == null) return error.InvalidStyle;
    if (style_value.gradient) |paint| {
        if (if (paint.* == .linear_stroke) style_value.pen == null else style_value.fill == null) return error.InvalidStyle;
        switch (paint.*) {
            .mesh_fill => |mesh| {
                if (mesh.vertices.len < 3 or mesh.triangles.len == 0) return error.InvalidStyle;
                for (mesh.vertices) |vertex| {
                    if (!std.math.isFinite(vertex.x) or !std.math.isFinite(vertex.y)) return error.NonFinite;
                    if (!vertex.color().valid()) return error.InvalidColor;
                }
                for (mesh.triangles) |triangle| for (triangle) |index| {
                    if (index >= mesh.vertices.len) return error.InvalidStyle;
                };
            },
            inline else => |ramp| {
                if (!ramp.start.isFinite() or !ramp.end.isFinite() or ramp.start.eql(ramp.end) or ramp.colors.len < 2) return error.InvalidStyle;
                for (ramp.colors) |color| if (!color.valid()) return error.InvalidColor;
            },
        }
    }
    if (style_value.fill) |fill| if (!fill.valid()) return error.InvalidColor;
    if (style_value.pen) |*pen| {
        if (!pen.color.valid()) return error.InvalidColor;
        if (!std.math.isFinite(pen.width) or pen.width < 0 or !std.math.isFinite(pen.miter_limit) or pen.miter_limit < 1 or !std.math.isFinite(pen.dash_phase)) return error.InvalidPen;
        if (pen.nib) |nib| nib.validate() catch return error.InvalidPen;
        if (pen.motion) |motion| {
            try motion.validate();
            if (pen.dash.len != 0) return error.InvalidPen;
        }
        var total: f64 = 0;
        for (pen.dash) |length| {
            if (!std.math.isFinite(length) or length < 0) return error.InvalidPen;
            total += length;
        }
        if (!std.math.isFinite(total) or (pen.dash.len != 0 and total <= 0)) return error.InvalidPen;
    }
}
pub fn validatePath(segments: []const Path.Segment, closed: bool) Error!void {
    var open = false;
    var drawable = false;
    for (segments) |segment| switch (segment) {
        .move => |p| {
            if (!p.isFinite()) return error.NonFinite;
            if (closed and open) return error.InvalidPath;
            open = true;
        },
        .line => |p| {
            if (!open) return error.InvalidPath;
            if (!p.isFinite()) return error.NonFinite;
            drawable = true;
        },
        .cubic => |c| {
            if (!open) return error.InvalidPath;
            if (!c.c1.isFinite() or !c.c2.isFinite() or !c.end.isFinite()) return error.NonFinite;
            drawable = true;
        },
        .close => {
            if (!open) return error.InvalidPath;
            open = false;
        },
    };
    // A move-only path is valid editable source geometry. Clip regions still
    // require a drawable, closed contour; empty drawing commands stay invalid.
    if (segments.len == 0 or (closed and (!drawable or open))) return error.InvalidPath;
}

test "copying solved curves owns the knot data and rolls back failed allocations" {
    const t = std.testing;
    var path_ = try @import("path/construct.zig").construct(t.allocator, &.{ .zero, .{ .x = 4, .y = 7 }, .{ .x = 9, .y = 2 } }, &.{ .smooth, .smooth }, .{});
    defer path_.deinit();
    var source = Storage.init(t.allocator);
    defer source.deinit();
    const draw = try source.path(&path_, &.{ .fill = .black }, .{});
    const view = try source.asGeometry().view(t.allocator, draw.path);
    try t.expect(view.knotRecords().ptr != path_.knotRecords().ptr);
    const exercise = struct {
        fn run(a: std.mem.Allocator, geometry: Geometry, command: PathCommand) !void {
            var target = Storage.init(a);
            defer target.deinit();
            try target.segments.ensureUnusedCapacity(a, command.path.count);
            const copy = target.copyPath(geometry, command, .independent) catch |err| {
                try t.expectEqual(@as(usize, 0), target.segments.items.len);
                try t.expectEqual(@as(usize, 0), target.knot_bytes);
                return err;
            };
            const from = try geometry.view(a, command.path);
            const to = try target.asGeometry().view(a, copy.path);
            try t.expectEqualDeep(from.knotRecords(), to.knotRecords());
            try t.expect(to.knotRecords().ptr != from.knotRecords().ptr);
            target.truncateGeometry(0);
            try t.expectEqual(@as(usize, 0), target.knot_blocks.items.len);
            try t.expectEqual(@as(usize, 0), target.knot_bytes);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, exercise.run, .{ source.asGeometry(), draw });
}
