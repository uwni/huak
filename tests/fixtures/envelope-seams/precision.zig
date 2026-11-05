//! Standalone evidence probe; no renderer or FFI. Run from the package root:
//! zig run -OReleaseSafe --dep drawing -Mroot=tests/fixtures/envelope-seams/precision.zig \
//!   -OReleaseSafe -Mdrawing=src/drawing/root.zig 2>target/seam-comparison/precision-native.csv
//!
//! Input controls and square offsets are even integers, hence exactly
//! representable at both origins. Normalize the actual path primitives before
//! any curve sampling or conversion of lines to polynomial controls.
const std = @import("std");
const drawing = @import("drawing");
const g = drawing.geometry;
const Point = g.Point;
const Path = drawing.Path;

const curves = [_]g.Cubic{
    .{ .p0 = .{ .x = 100, .y = 44 }, .p1 = .{ .x = 100, .y = 54 }, .p2 = .{ .x = 90, .y = 64 }, .p3 = .{ .x = 80, .y = 64 } },
    .{ .p0 = .{ .x = 80, .y = 64 }, .p1 = .{ .x = 70, .y = 64 }, .p2 = .{ .x = 60, .y = 54 }, .p3 = .{ .x = 60, .y = 44 } },
    .{ .p0 = .{ .x = 60, .y = 44 }, .p1 = .{ .x = 60, .y = 34 }, .p2 = .{ .x = 70, .y = 24 }, .p3 = .{ .x = 80, .y = 24 } },
    .{ .p0 = .{ .x = 80, .y = 24 }, .p1 = .{ .x = 90, .y = 24 }, .p2 = .{ .x = 100, .y = 34 }, .p3 = .{ .x = 100, .y = 44 } },
};
const vertices = [_]Point{ .{ .x = -4, .y = -4 }, .{ .x = 4, .y = -4 }, .{ .x = 4, .y = 4 }, .{ .x = -4, .y = 4 } };

fn printRow(name: []const u8, index: usize, kind: []const u8, p0: Point, p1: Point, p2: Point, p3: Point) void {
    std.debug.print("{s},{d},{s},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17}\n", .{
        name, index, kind, p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y,
    });
}

fn emit(name: []const u8, path: Path, origin: Point) void {
    var current: Point = .zero;
    var start: Point = .zero;
    for (path.segments.items, 0..) |segment, index| switch (segment) {
        .move => |point| {
            current = point.sub(origin);
            start = current;
            printRow(name, index, "move", current, current, current, current);
        },
        .line => |point| {
            const end = point.sub(origin);
            printRow(name, index, "line", current, current, end, end);
            current = end;
        },
        .cubic => |curve| {
            const end = curve.end.sub(origin);
            printRow(name, index, "cubic", current, curve.c1.sub(origin), curve.c2.sub(origin), end);
            current = end;
        },
        .close => {
            printRow(name, index, "close", current, current, start, start);
            current = start;
        },
    };
}

fn normalize(path: *Path, origin: Point) void {
    for (path.segments.items) |*segment| switch (segment.*) {
        .move => |point| segment.move = point.sub(origin),
        .line => |point| segment.line = point.sub(origin),
        .cubic => |curve| segment.cubic = .{ .c1 = curve.c1.sub(origin), .c2 = curve.c2.sub(origin), .end = curve.end.sub(origin) },
        .close => {},
    };
    if (path.current) |point| path.current = point.sub(origin);
    if (path.start) |point| path.start = point.sub(origin);
}

const Difference = struct {
    max_control_coordinate: f64 = 0,
    max_same_parameter_sample: f64 = 0,

    fn point(self: *Difference, first: Point, second: Point) void {
        self.max_control_coordinate = @max(self.max_control_coordinate, @max(@abs(first.x - second.x), @abs(first.y - second.y)));
        self.max_same_parameter_sample = @max(self.max_same_parameter_sample, first.distance(second));
    }
};

fn compare(first: Path, second: Path) !Difference {
    if (first.segments.items.len != second.segments.items.len) return error.DifferentPrimitivePartition;
    var result: Difference = .{};
    var first_current: Point = .zero;
    var second_current: Point = .zero;
    for (first.segments.items, second.segments.items) |a, b| {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.DifferentPrimitivePartition;
        switch (a) {
            .move => |point| {
                first_current = point;
                second_current = b.move;
                result.point(point, b.move);
            },
            .line => |point| {
                first_current = point;
                second_current = b.line;
                result.point(point, b.line);
            },
            .cubic => |curve| {
                const actual = b.cubic;
                const p: g.Cubic = .{ .p0 = first_current, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end };
                const q: g.Cubic = .{ .p0 = second_current, .p1 = actual.c1, .p2 = actual.c2, .p3 = actual.end };
                // Control differences and on-curve differences are distinct:
                // sampling compares corresponding parameters, not Hausdorff.
                for ([_][2]Point{ .{ curve.c1, actual.c1 }, .{ curve.c2, actual.c2 } }) |pair| {
                    result.max_control_coordinate = @max(result.max_control_coordinate, @max(@abs(pair[0].x - pair[1].x), @abs(pair[0].y - pair[1].y)));
                }
                for (0..1025) |index| {
                    const time = @as(f64, @floatFromInt(index)) / 1024;
                    result.max_same_parameter_sample = @max(result.max_same_parameter_sample, p.at(time).distance(q.at(time)));
                }
                first_current = curve.end;
                second_current = actual.end;
                result.point(curve.end, actual.end);
            },
            .close => {},
        }
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("case,index,kind,p0x,p0y,p1x,p1y,p2x,p2y,p3x,p3y\n", .{});
    var unit: ?Path = null;
    defer if (unit) |*path| path.deinit();
    for ([_]struct { name: []const u8, origin: Point }{
        .{ .name = "unit", .origin = .zero },
        .{ .name = "offset-16", .origin = .{ .x = 1e16, .y = 1e16 } },
    }) |case| {
        for (curves) |curve| for ([_]Point{ curve.p0, curve.p1, curve.p2, curve.p3 }) |point| {
            if (!std.meta.eql(point, point.add(case.origin).sub(case.origin))) return error.InputRounding;
            for (vertices) |vertex| {
                if (!std.meta.eql(point.add(vertex), point.add(case.origin).add(vertex).sub(case.origin))) return error.InputRounding;
            }
        };
        var path = Path.init(init.gpa);
        defer path.deinit();
        try path.moveTo(curves[0].p0.add(case.origin));
        for (curves) |curve| try path.cubicTo(curve.p1.add(case.origin), curve.p2.add(case.origin), curve.p3.add(case.origin));
        try path.close();
        var result = try drawing.pen.strokeOutline(init.gpa, .{ .polygon = &vertices }, path, .{ .tolerance = 1e-3, .cap = .round, .join = .round });
        defer result.deinit();
        normalize(&result, case.origin);
        emit(case.name, result, .zero);
        if (unit) |baseline| {
            const difference = try compare(baseline, result);
            const summary = try std.fmt.allocPrint(init.gpa, "production strokeOutline; tolerance=0.001; origins=(0,0),(1e16,1e16)\n" ++
                "max_normalized_control_coordinate_difference={d:.17}\n" ++
                "max_corresponding_curve_sample_distance={d:.17}; subdivisions_per_cubic=1024\n" ++
                "The sampled metric is a lower bound on maximum same-parameter displacement, not a visible-boundary Hausdorff proof.\n", .{ difference.max_control_coordinate, difference.max_same_parameter_sample });
            defer init.gpa.free(summary);
            try std.Io.File.stdout().writeStreamingAll(init.io, summary);
        } else unit = try result.clone(init.gpa);
    }
}
