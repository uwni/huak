//! Coverage from actual MetaPost draw -> EPS -> Ghostscript pixels, independent
//! of the envelope recipe used by both the implementation and control oracle.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const support = @import("envelope.zig");
const Point = core.geometry.Point;
const Path = core.Path;
const Case = enum { @"small-loop", @"small-loop-reversed", @"bowtie-closed", @"self-cross-open", @"repeat-same", @"repeat-opposite" };
const square = [_]Point{ .{ .x = -2, .y = -2 }, .{ .x = 2, .y = -2 }, .{ .x = 2, .y = 2 }, .{ .x = -2, .y = 2 } };
const reference = @embedFile("../fixtures/envelope-coverage.csv");

fn centerline(case: Case) !Path {
    if (case == .@"small-loop" or case == .@"small-loop-reversed") {
        var circle = try Path.circle(t.allocator, .zero, 1);
        if (case == .@"small-loop") return circle;
        defer circle.deinit();
        return circle.reverse(t.allocator);
    }
    var path: Path = .init(t.allocator);
    errdefer path.deinit();
    if (case == .@"bowtie-closed" or case == .@"self-cross-open") {
        try path.moveTo(.{ .x = -6, .y = -4 });
        for ([_]Point{ .{ .x = 6, .y = 4 }, .{ .x = -6, .y = 4 }, .{ .x = 6, .y = -4 } }) |point| try path.lineTo(point);
        if (case == .@"bowtie-closed") try path.close();
    } else {
        try path.moveTo(.{ .x = -4, .y = -4 });
        for ([_]Point{ .{ .x = 4, .y = -4 }, .{ .x = 4, .y = 4 }, .{ .x = -4, .y = 4 }, .{ .x = -4, .y = -4 } }) |point| try path.lineTo(point);
        const same = [_]Point{ .{ .x = 4, .y = -4 }, .{ .x = 4, .y = 4 }, .{ .x = -4, .y = 4 } };
        const opposite = [_]Point{ .{ .x = -4, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = -4 } };
        for (if (case == .@"repeat-same") same else opposite) |point| try path.lineTo(point);
        try path.close();
    }
    return path;
}

test "complete strokes match independently rendered MetaPost fat loops self crossings and repeated cycles" {
    var failures: usize = 0;
    inline for (std.meta.tags(Case)) |case| {
        var center = try centerline(case);
        defer center.deinit();
        var stroke = try core.pen.strokeOutline(t.allocator, .{ .polygon = &square }, center, .{ .tolerance = 1e-4, .cap = .round, .join = .round });
        defer stroke.deinit();
        const curves = try support.curves(t.allocator, stroke);
        defer t.allocator.free(curves);
        var rows = std.mem.tokenizeScalar(u8, reference, '\n');
        try t.expectEqualStrings("case,x,y,ink", rows.next().?);
        var checked: usize = 0;
        var center_checked = false;
        while (rows.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ',');
            if (!std.mem.eql(u8, fields.next().?, @tagName(case))) continue;
            const point: Point = .{ .x = try std.fmt.parseFloat(f64, fields.next().?), .y = try std.fmt.parseFloat(f64, fields.next().?) };
            const value = fields.next().?;
            try t.expect(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "1"));
            try t.expect(fields.next() == null);
            const expected = std.mem.eql(u8, value, "1");
            const actual = try support.winding(curves, point) != 0;
            if (expected != actual) {
                if (failures < 12) std.debug.print("actual MetaPost draw {s} at {any}: expected ink={any}, actual={any}\n", .{ @tagName(case), point, expected, actual });
                failures += 1;
            }
            if (point.x == 0.125 and point.y == 0.625) {
                center_checked = true;
                if (case == .@"small-loop" or case == .@"small-loop-reversed") try t.expect(expected and actual);
            }
            checked += 1;
        }
        try t.expectEqual(@as(usize, 169), checked);
        try t.expect(center_checked);
    }
    try t.expectEqual(@as(usize, 0), failures);
}
