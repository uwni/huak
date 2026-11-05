//! Native circular/elliptic and convex polygon nibs. makePen follows MetaPost:
//! it takes the convex hull of the path knots, not its Bézier control points.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{ InvalidNib, InvalidPath, NonFinite, ZeroVector };
const square_vertices = [_]g.Point{
    .{ .x = -0.5, .y = -0.5 }, .{ .x = 0.5, .y = -0.5 },
    .{ .x = 0.5, .y = 0.5 },   .{ .x = -0.5, .y = 0.5 },
};

/// Borrowed immutable shape. Polygon vertices are counterclockwise, convex,
/// and have no repeated final vertex. One- and two-vertex nibs are permitted.
/// Store an OwnedNib, or copy vertices, when retaining this view.
pub const Nib = union(enum) {
    ellipse: g.Transform,
    polygon: []const g.Point,

    pub fn circle() Nib {
        return .{ .ellipse = .{} };
    }
    pub fn square() Nib {
        return .{ .polygon = &square_vertices };
    }
    pub fn validate(self: Nib) Error!void {
        switch (self) {
            .ellipse => |transform| if (!transform.isFinite()) return error.NonFinite,
            .polygon => |vertices| {
                if (vertices.len == 0) return error.InvalidNib;
                for (vertices) |point| if (!point.isFinite()) return error.NonFinite;
                if (vertices.len > 2) {
                    var positive = false;
                    var wraps: usize = 0;
                    for (vertices, 0..) |point, index| {
                        const next = vertices[(index + 1) % vertices.len];
                        const last = vertices[(index + 2) % vertices.len];
                        const before = next.sub(point);
                        const after = last.sub(next);
                        if ((before.x == 0 and before.y == 0) or (after.x == 0 and after.y == 0) or !before.isFinite() or !after.isFinite()) return error.InvalidNib;
                        const sign = try orientation(point, next, last);
                        if (sign < 0) return error.InvalidNib;
                        if (sign == 0 and (try before.normalized()).dot(try after.normalized()) < 0) return error.InvalidNib;
                        if (!upperHalf(before) and upperHalf(after)) wraps += 1;
                        positive = positive or sign > 0;
                    }
                    // Positive local turns alone also admit a self-crossing
                    // star. Convex edge directions must wind exactly once.
                    if (!positive or wraps != 1) return error.InvalidNib;
                }
            },
        }
    }
    pub fn clone(self: Nib, allocator: Allocator) Error!OwnedNib {
        try self.validate();
        return .{ .allocator = allocator, .nib = switch (self) {
            .ellipse => self,
            .polygon => |vertices| .{ .polygon = try allocator.dupe(g.Point, vertices) },
        } };
    }
    pub fn transformed(self: Nib, allocator: Allocator, transform: g.Transform) Error!OwnedNib {
        try self.validate();
        if (!transform.isFinite()) return error.NonFinite;
        return switch (self) {
            .ellipse => |ellipse| result: {
                const combined = ellipse.then(transform);
                if (!combined.isFinite()) return error.NonFinite;
                break :result .{ .allocator = allocator, .nib = .{ .ellipse = combined } };
            },
            .polygon => |vertices| result: {
                const transformed_vertices = try allocator.alloc(g.Point, vertices.len);
                defer allocator.free(transformed_vertices);
                for (vertices, transformed_vertices) |point, *destination| {
                    destination.* = transform.apply(point);
                    if (!destination.isFinite()) return error.NonFinite;
                }
                // Reflections reverse orientation; singular transforms can
                // collapse a nib to a line or point. A fresh hull handles both.
                break :result .{ .allocator = allocator, .nib = .{ .polygon = try convexHullScratch(allocator, transformed_vertices) } };
            },
        };
    }
    /// Map a centerline into this ellipse's unit-circle coordinates. The
    /// caller owns the result; polygon and singular nibs need no normalization.
    pub fn normalizePath(self: Nib, allocator: Allocator, source: Path) !?Path {
        if (self != .ellipse) return null;
        var linear = self.ellipse;
        linear.e = 0;
        linear.f = 0;
        const inverse = linear.inverse() catch return null;
        return try source.transformed(allocator, inverse);
    }
    pub fn bounds(self: Nib) Error!g.BBox {
        try self.validate();
        const result = switch (self) {
            .ellipse => |transform| result: {
                const half_width = std.math.hypot(transform.a * 0.5, transform.c * 0.5);
                const half_height = std.math.hypot(transform.b * 0.5, transform.d * 0.5);
                break :result g.BBox{ .min = .{ .x = transform.e - half_width, .y = transform.f - half_height }, .max = .{ .x = transform.e + half_width, .y = transform.f + half_height } };
            },
            .polygon => |vertices| result: {
                var box = g.BBox.fromPoint(vertices[0]);
                for (vertices[1..]) |point| box = box.include(point);
                break :result box;
            },
        };
        if (!result.min.isFinite() or !result.max.isFinite()) return error.NonFinite;
        return result;
    }
    /// Point maximizing dot(point, normal). At a flat edge the first extremal
    /// vertex is returned; the support value is independent of that choice.
    pub fn support(self: Nib, normal: g.Point) Error!g.Point {
        try self.validate();
        const direction = try normal.normalized();
        return switch (self) {
            .ellipse => |transform| result: {
                // The transform maps a diameter-one circle, so halve before
                // multiplying/adding. The full matrix norm can overflow even
                // while every coordinate of the actual nib is representable.
                const local = g.Point{ .x = (transform.a * 0.5) * direction.x + (transform.b * 0.5) * direction.y, .y = (transform.c * 0.5) * direction.x + (transform.d * 0.5) * direction.y };
                if (!local.isFinite()) return error.NonFinite;
                const unit = local.normalized() catch |err| switch (err) {
                    error.ZeroVector => break :result .{ .x = transform.e, .y = transform.f },
                    else => return err,
                };
                const point = transform.apply(unit.scale(0.5));
                if (!point.isFinite()) return error.NonFinite;
                break :result point;
            },
            .polygon => |vertices| result: {
                var best = vertices[0];
                var projection = best.dot(direction);
                if (!std.math.isFinite(projection)) return error.NonFinite;
                for (vertices[1..]) |point| {
                    const candidate = point.dot(direction);
                    if (!std.math.isFinite(candidate)) return error.NonFinite;
                    if (candidate > projection) {
                        best = point;
                        projection = candidate;
                    }
                }
                break :result best;
            },
        };
    }
    /// MetaPost penoffset: extremal point to the right of a path direction.
    pub fn offset(self: Nib, direction: g.Point) Error!g.Point {
        return self.support(.{ .x = direction.y, .y = -direction.x });
    }
    /// Ellipses use the same four-cubic approximation as Path.circle. This
    /// preserves editable curves; strokeOutline uses an error-bounded mesh.
    pub fn makePath(self: Nib, allocator: Allocator) !Path {
        try self.validate();
        switch (self) {
            .ellipse => |transform| {
                var result = try Path.circle(allocator, .zero, 0.5);
                errdefer result.deinit();
                try result.transform(transform);
                return result;
            },
            .polygon => |vertices| {
                var result = Path.init(allocator);
                errdefer result.deinit();
                try result.moveTo(vertices[0]);
                for (vertices[1..]) |point| try result.lineTo(point);
                try result.close();
                return result;
            },
        }
    }
};

pub const OwnedNib = struct {
    allocator: Allocator,
    nib: Nib,

    pub fn deinit(self: *OwnedNib) void {
        if (self.nib == .polygon) self.allocator.free(self.nib.polygon);
        self.* = undefined;
    }
};

pub fn makePen(allocator: Allocator, path: Path) Error!OwnedNib {
    var points: std.ArrayList(g.Point) = .empty;
    defer points.deinit(allocator);
    if (path.segments.items.len < 2 or path.segments.items[0] != .move or path.segments.items[path.segments.items.len - 1] != .close) return error.InvalidPath;
    for (path.segments.items, 0..) |segment, index| switch (segment) {
        .move => |point| {
            if (index != 0) return error.InvalidPath;
            try points.append(allocator, point);
        },
        .line => |point| try points.append(allocator, point),
        .cubic => |curve| {
            if (!curve.c1.isFinite() or !curve.c2.isFinite()) return error.NonFinite;
            try points.append(allocator, curve.end);
        },
        .close => if (index + 1 != path.segments.items.len) return error.InvalidPath,
    };
    return .{ .allocator = allocator, .nib = .{ .polygon = try convexHullScratch(allocator, points.items) } };
}

fn lessThan(_: void, a: g.Point, b: g.Point) bool {
    return a.x < b.x or (a.x == b.x and a.y < b.y);
}
fn equal(a: g.Point, b: g.Point) bool {
    return a.x == b.x and a.y == b.y;
}
fn upperHalf(vector: g.Point) bool {
    return vector.y > 0 or (vector.y == 0 and vector.x >= 0);
}
fn orientation(a: g.Point, b: g.Point, c: g.Point) Error!f64 {
    const ab = b.sub(a);
    const ac = c.sub(a);
    if (!ab.isFinite() or !ac.isFinite()) return error.NonFinite;
    const scale = @max(@max(@abs(ab.x), @abs(ab.y)), @max(@abs(ac.x), @abs(ac.y)));
    if (scale == 0) return 0;
    return (ab.x / scale) * (ac.y / scale) - (ab.y / scale) * (ac.x / scale);
}

/// Andrew's monotone-chain hull. Sorting uses the standard library; geometric
/// orientation is scaled to avoid overflowing on finite large coordinates.
pub fn convexHull(allocator: Allocator, input: []const g.Point) Error![]const g.Point {
    if (input.len == 0) return error.InvalidNib;
    const points = try allocator.dupe(g.Point, input);
    defer allocator.free(points);
    return convexHullScratch(allocator, points);
}

/// Internal mutable scratch for callers that already own their input buffer.
/// Sorting may change the buffer; the returned hull is independently owned.
pub fn convexHullScratch(allocator: Allocator, points: []g.Point) Error![]const g.Point {
    if (points.len == 0) return error.InvalidNib;
    for (points) |point| if (!point.isFinite()) return error.NonFinite;
    std.mem.sort(g.Point, points, {}, lessThan);
    var unique: usize = 0;
    for (points) |point| {
        if (unique == 0 or !equal(points[unique - 1], point)) {
            points[unique] = point;
            unique += 1;
        }
    }
    if (unique < 3) return allocator.dupe(g.Point, points[0..unique]);
    const capacity = std.math.mul(usize, unique, 2) catch return error.OutOfMemory;
    const hull = try allocator.alloc(g.Point, capacity);
    errdefer allocator.free(hull);
    var count: usize = 0;
    for (points[0..unique]) |point| {
        while (count >= 2 and try orientation(hull[count - 2], hull[count - 1], point) <= 0) count -= 1;
        hull[count] = point;
        count += 1;
    }
    const lower_count = count;
    var index = unique - 1;
    while (index != 0) {
        index -= 1;
        const point = points[index];
        while (count > lower_count and try orientation(hull[count - 2], hull[count - 1], point) <= 0) count -= 1;
        hull[count] = point;
        count += 1;
    }
    return allocator.realloc(hull, count - 1);
}

test "makepen convexifies knots and ignores cubic handles" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.lineTo(.{ .x = 1, .y = 1 });
    try path.cubicTo(.{ .x = 100, .y = -100 }, .{ .x = -100, .y = 100 }, .{ .x = 0, .y = 4 });
    try path.close();
    var nib = try makePen(std.testing.allocator, path);
    defer nib.deinit();
    try std.testing.expectEqual(@as(usize, 3), nib.nib.polygon.len);
    try std.testing.expectEqual(g.Point{ .x = 4, .y = 0 }, try nib.nib.support(.{ .x = 1, .y = 0 }));
    try std.testing.expectEqual(@as(f64, 4), (try nib.nib.bounds()).height());
}

test "ellipse support and independent transforms include nib offsets" {
    var ellipse = try Nib.circle().transformed(std.testing.allocator, g.Transform.scaling(8, 2).then(g.Transform.rotation(std.math.pi / 2.0)).then(g.Transform.translation(3, 4)));
    defer ellipse.deinit();
    const box = try ellipse.nib.bounds();
    try std.testing.expectApproxEqAbs(@as(f64, 2), box.width(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8), box.height(), 1e-12);
    const right = try ellipse.nib.support(.{ .x = 1, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 4), right.x, 1e-12);
    const down = try ellipse.nib.offset(.{ .x = 1, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0), down.y, 1e-12);
}

test "polygon reflection and singular transforms retain valid convex nibs" {
    var reflected = try Nib.square().transformed(std.testing.allocator, g.Transform.scaling(-4, 2));
    defer reflected.deinit();
    try reflected.nib.validate();
    var line = try reflected.nib.transformed(std.testing.allocator, g.Transform.scaling(1, 0));
    defer line.deinit();
    try std.testing.expectEqual(@as(usize, 2), line.nib.polygon.len);
    try std.testing.expectEqual(@as(f64, 0), (try line.nib.bounds()).height());
    var point = try line.nib.transformed(std.testing.allocator, g.Transform.scaling(0, 0));
    defer point.deinit();
    try std.testing.expectEqual(@as(usize, 1), point.nib.polygon.len);
}

test "nib makepath snapshots shape and rejects malformed source paths" {
    var polygon = try Nib.square().makePath(std.testing.allocator);
    defer polygon.deinit();
    var owned = try makePen(std.testing.allocator, polygon);
    defer owned.deinit();
    try polygon.transform(g.Transform.scaling(20, 20));
    try std.testing.expectEqual(@as(f64, 1), (try owned.nib.bounds()).width());
    try std.testing.expectError(error.ZeroVector, owned.nib.support(.zero));
    var open = Path.init(std.testing.allocator);
    defer open.deinit();
    try open.moveTo(.zero);
    try std.testing.expectError(error.InvalidPath, makePen(std.testing.allocator, open));
}

test "nib validation rejects self-crossing positive-turn stars and duplicate edges" {
    const star = [_]g.Point{ .{ .x = 0, .y = 3 }, .{ .x = -2, .y = -3 }, .{ .x = 3, .y = 1 }, .{ .x = -3, .y = 1 }, .{ .x = 2, .y = -3 } };
    try std.testing.expectError(error.InvalidNib, (Nib{ .polygon = &star }).validate());
    const duplicate = [_]g.Point{ .zero, .zero, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
    try std.testing.expectError(error.InvalidNib, (Nib{ .polygon = &duplicate }).validate());
}

test "diameter transforms do not overflow when the physical ellipse is finite" {
    const ellipse: Nib = .{ .ellipse = .{ .a = 1.7e308, .b = 1.7e308, .c = 1.7e308, .d = 1.7e308 } };
    const box = try ellipse.bounds();
    try std.testing.expect(box.min.isFinite() and box.max.isFinite());
    const point = try ellipse.support(.{ .x = 1, .y = 1 });
    try std.testing.expect(point.isFinite());
    try std.testing.expectApproxEqRel(@as(f64, 1.2020815280171308e308), point.x, 1e-14);
}

test "borrowed and mutable hull inputs keep independent result ownership" {
    var input = [_]g.Point{
        .{ .x = 2, .y = 2 }, .{ .x = -0.0, .y = 0.0 }, .{ .x = 2, .y = 0 },
        .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 2 },      .{ .x = -0.0, .y = 0.0 },
    };
    const snapshot = input;
    var scratch = input;
    const borrowed = try convexHull(std.testing.allocator, &input);
    defer std.testing.allocator.free(borrowed);
    const mutable = try convexHullScratch(std.testing.allocator, &scratch);
    defer std.testing.allocator.free(mutable);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&snapshot), std.mem.asBytes(&input));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(borrowed), std.mem.sliceAsBytes(mutable));
    scratch[0] = .{ .x = 99, .y = 99 };
    try std.testing.expectEqual(@as(f64, 0), mutable[0].x);

    var square = [_]g.Point{ .{ .x = -1, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = -1, .y = 1 } };
    const square_snapshot = square;
    var reflected = try (Nib{ .polygon = &square }).transformed(std.testing.allocator, .{ .a = -2, .d = 3 });
    defer reflected.deinit();
    try reflected.nib.validate();
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&square_snapshot), std.mem.asBytes(&square));
}

fn exerciseHullScratch(allocator: Allocator) !void {
    var points = [_]g.Point{ .{ .x = 1, .y = 1 }, .zero, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
    const hull = try convexHullScratch(allocator, &points);
    defer allocator.free(hull);
    var transformed = try Nib.square().transformed(allocator, .{ .a = -2, .d = 3 });
    defer transformed.deinit();
    try transformed.nib.validate();
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.lineTo(.{ .x = 0, .y = 1 });
    try path.close();
    var made = try makePen(allocator, path);
    defer made.deinit();
    try made.nib.validate();
    try std.testing.expectEqual(@as(usize, 4), path.segments.items.len);
}

test "mutable hull callers release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseHullScratch, .{});
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), exerciseHullScratch, .{});
}
