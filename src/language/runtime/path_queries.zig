//! Builtins for measuring, sampling, intersecting, crossing and bounding paths.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const Measure = @import("../../drawing/path/Measure.zig");
const path_crossings = @import("../../drawing/path/crossings.zig");
const types = @import("../types.zig");
const units = types.units;
const builtin = @import("../builtin.zig");
const renderer = @import("../../render/root.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const object_handles = @import("object_handles.zig");
const builtin_calls = @import("builtin_calls.zig");
const lengthPoints = conversions.lengthPoints;
const numeric = conversions.numeric;
const checkedIndex = conversions.checkedIndex;
const lengthResult = conversions.lengthResult;
const sequence = conversions.sequence;

/// Measuring, sampling, intersecting, crossing and bounding paths.
pub fn invoke(self: *Runtime, a: std.mem.Allocator, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .measure => {
            var options: Measure.Options = .{};
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            var measure = try Measure.init(self.gpa, try self.path(arg.curve), options);
            errdefer measure.deinit();
            return conversions.store(self, Measure, &self.measures, measure, .measure);
        },
        .point_at, .tangent_at => {
            const curve = try (try self.path(arg.curve)).curveAt(try numeric(arg.time));
            return .{ .vec2 = types.Vec2.fromPoint(if (id == .point_at) curve.curve.at(curve.t) else curve.curve.derivative(curve.t)) };
        },
        .signed_area => return .{ .number = (try self.path(arg.curve)).signedArea() },
        .arclength, .sample_path, .sample_at_length, .sample_at_fraction, .samples_at_length => {
            var options: Measure.Options = .{};
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            var temporary: ?Measure = null;
            defer if (temporary) |*value| value.deinit();
            const measure = if (arg.curve.valueType() == .measure) measured: {
                if (arg.tolerance != null) return error.MeasurementToleranceIsFixed;
                break :measured self.measures.items[try checkedIndex(arg.curve, .measure, self.measures.items.len)];
            } else measured: {
                temporary = try Measure.init(self.gpa, try self.path(arg.curve), options);
                break :measured temporary.?;
            };
            switch (id) {
                .arclength => return lengthResult(measure.length),
                .sample_at_length => return sampleValue(a, try sampleAtLength(measure, arg.distance)),
                .sample_at_fraction => return sampleValue(a, try measure.sampleNormalized(try numeric(arg.fraction))),
                .samples_at_length => {
                    const distances = try sequence(arg.distances);
                    if (distances.len > options.max_segments) return error.GeometryWorkLimit;
                    const rows = try a.alloc(Value, distances.len);
                    for (rows, distances) |*row, distance| row.* = try sampleValue(a, try sampleAtLength(measure, distance));
                    return types.listView(rows);
                },
                .sample_path => {
                    const count = if (arg.count == .int) std.math.cast(usize, arg.count.int) orelse return error.InvalidSampleCount else return error.TypeMismatch;
                    if (count < 2) return error.InvalidSampleCount;
                    const samples = try measure.samples(self.gpa, count);
                    defer self.gpa.free(samples);
                    const rows = try a.alloc(Value, samples.len);
                    for (rows, samples) |*row, sample| row.* = try sampleValue(a, sample);
                    return types.listView(rows);
                },
                else => unreachable,
            }
        },
        .bounds => {
            const box = switch (arg.object.valueType()) {
                .path => (try self.path(arg.object)).bounds(),
                .object, .picture => value: {
                    var selected = try object_handles.objectSnapshot(self, arg.object, false);
                    defer selected.deinit();
                    break :value try renderer.bounds(&selected.picture, self.frames.items);
                },
                else => return error.TypeMismatch,
            } orelse return types.listView(&.{});
            return types.listView(try a.dupe(Value, &.{ .{ .vec2 = types.Vec2.fromPoint(box.min) }, .{ .vec2 = types.Vec2.fromPoint(box.max) } }));
        },
        .intersections, .intersection_times => {
            const first = try self.path(arg.first);
            const second = try self.path(arg.second);
            const tolerance = if (arg.tolerance) |given| try lengthPoints(given) else 1e-8;
            return if (id == .intersection_times) intersections(self, a, first, second, tolerance, true) else intersections(self, a, first, second, tolerance, false);
        },
        .path_crossings => {
            const values = try sequence(arg.curves);
            if (values.len > 65536) return error.GeometryWorkLimit;
            const curves = try self.gpa.alloc(Path, values.len);
            defer self.gpa.free(curves);
            for (curves, values) |*curve, value| curve.* = try self.path(value);
            const tolerance = if (arg.tolerance) |given| try lengthPoints(given) else 1e-8;
            const crossings = try path_crossings.find(self.gpa, curves, .{ .tolerance = tolerance });
            defer self.gpa.free(crossings);
            const rows = try a.alloc(Value, crossings.len);
            for (rows, crossings) |*row, crossing| row.* = types.listView(try a.dupe(Value, &.{
                .{ .vec2 = types.Vec2.fromPoint(crossing.point) },
                .{ .int = @intCast(crossing.first.path) },
                .{ .int = @intCast(crossing.first.contour) },
                .{ .number = crossing.first.time },
                .{ .int = @intCast(crossing.second.path) },
                .{ .int = @intCast(crossing.second.contour) },
                .{ .number = crossing.second.time },
            }));
            return types.listView(rows);
        },
        else => comptime unreachable,
    }
}

fn intersections(self: *Runtime, a: std.mem.Allocator, first: Path, second: Path, tolerance: f64, comptime times: bool) !Value {
    const hits = if (times) try Path.intersect.intersectionDetails(first, self.gpa, second, tolerance) else try Path.intersect.intersections(first, self.gpa, second, tolerance);
    defer self.gpa.free(hits);
    const values = try a.alloc(Value, hits.len);
    for (hits, values) |hit, *value| value.* = .{ .vec2 = if (times) .{ .x = hit.a, .y = hit.b } else types.Vec2.fromPoint(hit) };
    return types.listView(values);
}

fn sampleValue(allocator: std.mem.Allocator, sample: Measure.Sample) !Value {
    return types.listView(try allocator.dupe(Value, &.{
        .{ .number = sample.u },
        .{ .vec2 = types.Vec2.fromPoint(sample.point) },
        .{ .vec2 = .{ .x = sample.tangent.x, .y = sample.tangent.y } },
        .{ .number = sample.time },
        .{ .int = @intCast(sample.contour) },
    }));
}

fn sampleAtLength(measure: Measure, distance: Value) !Measure.Sample {
    const points = try lengthPoints(distance);
    // Compare in the caller's canonical units before converting to native
    // distance: a returned length must address its own endpoint exactly.
    if (distance == .quantity and measure.length > 0)
        return measure.sampleNormalized(distance.quantity.value / units.fromPoints(measure.length).value);
    return measure.sample(points);
}

test "path queries keep source geometry and release native scratch and caller result graphs across OOM" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var outputs: std.heap.ArenaAllocator = .init(allocator);
            defer outputs.deinit();
            const out = outputs.allocator();
            var unused_library: typst.Library = undefined;
            var runtime = try Runtime.init(allocator, allocator, &unused_library, .{});
            defer runtime.deinit();
            const curve = try builtin_calls.invoke(&runtime, out, .bezier, &.{
                .{ .vec2 = .zero },
                .{ .vec2 = .{ .x = 0, .y = 2 } },
                .{ .vec2 = .{ .x = 2, .y = 2 } },
                .{ .vec2 = .{ .x = 2, .y = 0 } },
            });
            const original = try runtime.path(curve);
            const controls = original.segments.items[1].cubic;
            const closed = try builtin_calls.invoke(&runtime, out, .closed, &.{curve});
            const closed_path = try runtime.path(closed);
            try std.testing.expect(!closed_path.open and closed_path.segments.items.len == 3);
            try std.testing.expect(closed_path.segments.items.ptr != original.segments.items.ptr);
            const arch_area = try builtin_calls.invoke(&runtime, out, .signed_area, &.{closed});
            try std.testing.expectApproxEqAbs(@as(f64, -2.4), arch_area.number, 1e-12);
            const rev_closed = try builtin_calls.invoke(&runtime, out, .reverse, &.{closed});
            try std.testing.expectApproxEqAbs(@as(f64, 2.4), (try builtin_calls.invoke(&runtime, out, .signed_area, &.{rev_closed})).number, 1e-12);
            const crossing = try builtin_calls.invoke(&runtime, out, .path, &.{
                .{ .vec2 = .{ .x = 1, .y = -1 } },
                .{ .vec2 = .{ .x = 1, .y = 2 } },
            });
            const times = try sequence(try builtin_calls.invoke(&runtime, out, .intersection_times, &.{ curve, crossing }));
            try std.testing.expectEqual(@as(usize, 1), times.len);
            try std.testing.expect(times[0].vec2.dimension.eql(.scalar));
            try std.testing.expectApproxEqAbs(@as(f64, 0.5), times[0].vec2.x, 1e-9);
            try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 6.0), times[0].vec2.y, 1e-9);

            const events = try sequence(try builtin_calls.invoke(&runtime, out, .path_crossings, &.{types.listView(&.{ curve, crossing })}));
            try std.testing.expectEqual(@as(usize, 1), events.len);
            const event = try sequence(events[0]);
            try std.testing.expectEqual(@as(usize, 7), event.len);
            try std.testing.expectEqual(@as(i64, 0), event[1].int);
            try std.testing.expectEqual(@as(i64, 0), event[2].int);
            try std.testing.expectEqual(@as(i64, 1), event[4].int);
            try std.testing.expectEqual(@as(i64, 0), event[5].int);
            try std.testing.expectApproxEqAbs(@as(f64, 0.5), event[3].number, 1e-9);
            try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 6.0), event[6].number, 1e-9);

            const nib = try builtin_calls.invoke(&runtime, out, .pensquare, &.{});
            const ranges = types.listView(&.{types.listView(&.{ .{ .int = 0 }, .{ .number = 0 }, .{ .number = 0.5 } })});
            const sections = try sequence(try builtin_calls.invoke(&runtime, out, .stroke_sections, &.{ crossing, nib, ranges }));
            try std.testing.expectEqual(@as(usize, 1), sections.len);
            try std.testing.expect((try runtime.path(sections[0])).segmentCount() != 0);

            const by_length = try builtin_calls.invoke(&runtime, out, .sample_at_length, &.{ curve, .{ .number = 2 } });
            const by_fraction = try builtin_calls.invoke(&runtime, out, .sample_at_fraction, &.{ curve, .{ .number = 0.5 } });
            const batch = try sequence(try builtin_calls.invoke(&runtime, out, .samples_at_length, &.{ curve, types.listView(&.{ .{ .number = 0 }, .{ .number = 2 } }) }));
            try std.testing.expectEqual(@as(usize, 2), batch.len);
            for ([_]Value{ by_length, by_fraction, batch[1] }) |value| {
                const row = try sequence(value);
                try std.testing.expectEqual(@as(usize, 5), row.len);
                try std.testing.expectApproxEqAbs(@as(f64, 0.5), row[0].number, 1e-3);
                const position = try row[1].vec2.nativePoint();
                try std.testing.expectApproxEqAbs(@as(f64, 1), position.x, 1e-3);
                try std.testing.expectApproxEqAbs(@as(f64, 1.5), position.y, 1e-3);
                try std.testing.expect(row[2].vec2.dimension.eql(.scalar));
                try std.testing.expectApproxEqAbs(@as(f64, 1), row[2].vec2.x, 1e-3);
                try std.testing.expectApproxEqAbs(@as(f64, 0), row[2].vec2.y, 1e-3);
                try std.testing.expectApproxEqAbs(@as(f64, 0.5), row[3].number, 1e-3);
                try std.testing.expectEqual(@as(i64, 0), row[4].int);
            }
            const start = try sequence(batch[0]);
            try std.testing.expectEqual(@as(usize, 5), start.len);
            try std.testing.expectEqual(@as(f64, 0), start[0].number);
            try std.testing.expectEqualDeep(g.Point.zero, try start[1].vec2.nativePoint());
            try std.testing.expectEqual(@as(f64, 0), start[3].number);
            const unchanged = try runtime.path(curve);
            try std.testing.expect(unchanged.open and unchanged.segments.items.len == 2);
            try std.testing.expectEqualDeep(controls, unchanged.segments.items[1].cubic);
            try std.testing.expect(runtime.engine == null);
        }
    };
    try Check.run(std.testing.allocator);
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), Check.run, .{});
}
