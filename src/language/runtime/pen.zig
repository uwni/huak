//! Builtins for pens, pen paths and offsets, envelopes, stroke outlines and sections; pen motion and pen storage.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const pen_geometry = @import("../../drawing/pen/root.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const builtin_calls = @import("builtin_calls.zig");
const lengthPoints = conversions.lengthPoints;
const string = conversions.string;
const numeric = conversions.numeric;
const lengths = conversions.lengths;
const sequence = conversions.sequence;
const point = conversions.point;
const angular = conversions.angular;

/// Stores a pen with its own copy of the dash, motion and nib arrays, so
/// pens share nothing with the values they were made from. The caller keeps
/// ownership of `value`'s arrays.
pub fn storePen(self: *Runtime, value: DisplayList.Pen) !Value {
    var copy = value;
    try copy.cloneData(self.gpa);
    errdefer copy.freeData(self.gpa);
    return conversions.store(self, DisplayList.Pen, &self.pens, copy, .pen);
}

/// Pens, pen paths and offsets, envelopes, stroke outlines and sections.
pub fn invoke(self: *Runtime, a: std.mem.Allocator, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .pen => {
            // Dash and motion are parsed into scratch memory released with
            // this call; the stored pen keeps its own copy.
            var temporary: std.heap.ArenaAllocator = .init(self.gpa);
            defer temporary.deinit();
            const scratch = temporary.allocator();
            var value = DisplayList.Pen{ .paint = try conversions.paint(self, arg.paint), .width = if (arg.width) |width| try lengthPoints(width) else 1 };
            if (arg.cap) |cap| value.cap = std.meta.stringToEnum(DisplayList.Cap, try string(cap)) orelse return error.InvalidPen;
            if (arg.join) |join| value.join = std.meta.stringToEnum(DisplayList.Join, try string(join)) orelse return error.InvalidPen;
            if (arg.miter_limit) |limit| value.miter_limit = try numeric(limit);
            if (arg.dash) |dash| value.dash = try lengths(scratch, try sequence(dash));
            if (arg.dash_phase) |phase| value.dash_phase = try lengthPoints(phase);
            if (arg.nib) |nib| {
                // The source contributes only immutable nib geometry;
                // this constructor independently specifies all paint state.
                value.nib = try (try conversions.penValue(self, nib)).fixedNib();
            }
            const legacy = arg.profile != null;
            if (legacy or arg.motion != null) {
                if (legacy and (arg.width != null or value.nib != null or arg.motion != null) or value.dash.len != 0) {
                    self.native_message = "profile supplies the full width of a solid circular pen; motion uses a solid base nib";
                    return error.InvalidPen;
                }
                if ((arg.cap != null and (!legacy or value.cap != .round)) or
                    (arg.join != null and (!legacy or value.join != .round)) or arg.miter_limit != null)
                {
                    self.native_message = "the moving nib defines its own ends and corners";
                    return error.InvalidPen;
                }
                value.cap = .round;
                value.join = .round;
                const tolerance = if (arg.tolerance) |given| try lengthPoints(given) else g.curve_tolerance;
                value.motion = readMotion(scratch, if (legacy) arg.profile.? else arg.motion.?, legacy, tolerance) catch |err| {
                    self.native_message = switch (err) {
                        error.InvalidFrameCorner => "frame corner must be strict, rotate, or overlap",
                        error.ConflictingFrameCorners => "path frames in one motion must use the same corner policy",
                        else => "motion requires a bounded polynomial or ordered [fraction,value] keys, nonnegative scale controls, and a positive physical tolerance",
                    };
                    if (legacy and err == error.InvalidMotion) return error.InvalidProfile;
                    return err;
                };
            } else if (arg.tolerance != null) return error.InvalidMotion;
            try DisplayList.validateStyle(&.{ .pen = value });
            return storePen(self, value);
        },
        .pencircle, .pensquare => {
            const size = if (id == .pencircle) arg.diameter else arg.width;
            const width = if (size) |given| try lengthPoints(given) else 1;
            if (!std.math.isFinite(width) or width < 0) return error.InvalidPen;
            const source = if (id == .pencircle) pen_geometry.Nib.circle() else pen_geometry.Nib.square();
            var transformed_nib = try source.transformed(self.gpa, .scaling(width, width));
            defer transformed_nib.deinit();
            return storePen(self, .{ .nib = transformed_nib.nib, .paint = if (arg.paint) |given| try conversions.paint(self, given) else .black, .cap = .round, .join = .round });
        },
        .makepen => {
            var retained = try pen_geometry.makePen(self.gpa, try self.path(arg.outline));
            defer retained.deinit();
            return storePen(self, .{ .nib = retained.nib, .paint = if (arg.paint) |given| try conversions.paint(self, given) else .black, .cap = .round, .join = .round });
        },
        .makepath, .penoffset => {
            const nib = try (try conversions.penValue(self, arg.pen)).fixedNib();
            if (id == .makepath) return self.pathResult(try nib.makePath(self.gpa));
            return .{ .vec2 = types.Vec2.fromPoint(try nib.offset(try point(arg.direction))) };
        },
        .envelope => {
            const brush = try conversions.penValue(self, arg.pen);
            var config: pen_geometry.EnvelopeOptions = .{ .cap = brush.cap, .join = brush.join, .miter_limit = brush.miter_limit };
            if (arg.tolerance) |given| config.tolerance = try lengthPoints(given);
            const result = pen_geometry.envelope(self.gpa, try brush.fixedNib(), try self.path(arg.curve), config) catch |err| {
                if (err == error.EllipticalPen) self.native_message = "envelope requires a polygonal pen; use pensquare or makepen";
                return err;
            };
            return self.pathResult(result);
        },
        .stroke_outline => {
            const tolerance = if (arg.tolerance) |given| try lengthPoints(given) else null;
            const brush = try conversions.penValue(self, arg.pen);
            return self.pathResult(try pen_geometry.footprint(self.gpa, try self.path(arg.curve), &brush, tolerance));
        },
        .stroke_sections => {
            const values = try sequence(arg.ranges);
            var options: pen_geometry.StrokeOptions = .{};
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            if (values.len > options.max_segments) return error.GeometryWorkLimit;
            const ranges = try self.gpa.alloc(pen_geometry.sections.Range, values.len);
            defer self.gpa.free(ranges);
            for (ranges, values) |*range, value| {
                const fields = try sequence(value);
                if (fields.len != 3 or fields[0] != .int) return error.TypeMismatch;
                range.* = .{
                    .contour = std.math.cast(usize, fields[0].int) orelse return error.InvalidParameter,
                    .begin = try numeric(fields[1]),
                    .end = try numeric(fields[2]),
                };
            }
            const sections = try pen_geometry.sections.extract(self.gpa, try self.path(arg.curve), try conversions.penValue(self, arg.pen), ranges, options);
            defer self.gpa.free(sections);
            var moved = false;
            defer if (!moved) for (sections) |*section| section.deinit();
            const rows = try a.alloc(Value, sections.len);
            errdefer a.free(rows);
            try conversions.pathResults(self, sections, rows);
            moved = true;
            return types.listView(rows);
        },
        else => comptime unreachable,
    }
}

fn readMotion(a: std.mem.Allocator, input: Value, legacy: bool, tolerance: f64) !*const pen_geometry.Motion {
    const Motion = pen_geometry.Motion;
    const values = try sequence(input);
    const tracks = try a.alloc(Motion.Track, if (legacy) 1 else values.len);
    var keys: std.ArrayList(Motion.Key) = .empty;
    var visits: usize = 0;
    var corner: ?Motion.Corner = null;
    for (tracks, 0..) |*track, i| {
        var stops = values;
        var kind: Motion.Kind = .scale;
        if (!legacy) {
            const op = try sequence(values[i]);
            if (op.len == 0) return error.InvalidMotion;
            kind = std.meta.stringToEnum(Motion.Kind, try string(op[0])) orelse return error.InvalidMotion;
            if (kind == .path_frame) {
                if (op.len > 2) return error.InvalidMotion;
                const mode: Motion.Corner = if (op.len == 1) .strict else std.meta.stringToEnum(Motion.Corner, try string(op[1])) orelse return error.InvalidFrameCorner;
                if (corner != null and corner.? != mode) return error.ConflictingFrameCorners;
                corner = mode;
                track.* = .{ .kind = kind, .first = keys.items.len, .len = 0 };
                continue;
            }
            if (op.len != 2) return error.InvalidMotion;
            const operand = op[1];
            const list = types.sequence(operand);
            if (list == null or (list.?.len > 0 and list.?[0] == .string)) {
                const polynomial = try @import("PenPolynomial.zig").read(operand, 0, &visits);
                track.* = try polynomial.append(kind, a, &keys);
                continue;
            }
            stops = list.?;
        }
        track.* = .{ .kind = kind, .first = keys.items.len, .len = stops.len };
        try keys.ensureUnusedCapacity(a, stops.len);
        for (stops) |stop| {
            const pair = try sequence(stop);
            if (pair.len != 2) return error.InvalidMotion;
            const v = if (legacy) try lengthPoints(pair[1]) else if (kind == .rotate) try angular(pair[1]) else try numeric(pair[1]);
            keys.appendAssumeCapacity(.{ .t = try numeric(pair[0]), .value = v });
        }
    }
    const motion = try a.create(Motion);
    motion.* = .{ .tracks = tracks, .keys = keys.items, .tolerance = tolerance, .corner = corner orelse .strict };
    try motion.validate();
    return motion;
}

fn penSnapshotAllocationScenario(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const points = [_]g.Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
    const brush = try storePen(&runtime, .{ .dash = &.{ 3, 2 }, .nib = .{ .polygon = &points } });
    const curve = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const item = try builtin_calls.invoke(&runtime, a, .draw, &.{ curve, brush });
    const host_value = runtime.host();
    const saved = try host_value.field(a, item, "pen");
    const replacement = try storePen(&runtime, .{});
    _ = try builtin_calls.invoke(&runtime, a, .object_style, &.{ item, .omitted, replacement });
    const pen = try conversions.penValue(&runtime, saved);
    try std.testing.expectEqualSlices(f64, &.{ 3, 2 }, pen.dash);
    try std.testing.expectEqualSlices(g.Point, &points, pen.nib.?.polygon);
    _ = try builtin_calls.invoke(&runtime, a, .draw, &.{ curve, saved });
}

test "queried pens retain dash and nib snapshots after source style replacement across OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, penSnapshotAllocationScenario, .{});
}
