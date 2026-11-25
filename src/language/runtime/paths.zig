//! Builtins for path construction and editing.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const path_construct = @import("../../drawing/path/construct.zig");
const path_fillet = @import("../../drawing/path/fillet.zig");
const hobby = @import("../../drawing/path/hobby.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const sequence = conversions.sequence;
const numeric = conversions.numeric;
const point = conversions.point;
const lengths = conversions.lengths;
const lengthPoints = conversions.lengthPoints;
const angular = conversions.angular;
const boolean = conversions.boolean;
const hasArgument = conversions.hasArgument;
const string = conversions.string;

/// Path construction and editing.
pub fn invoke(self: *Runtime, a: std.mem.Allocator, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .len => return .{ .int = @intCast(switch (arg.value) {
            .handle => if (arg.value.valueType() == .path) (try self.path(arg.value)).segmentCount() else return error.TypeMismatch,
            else => return error.TypeMismatch,
        }) },
        .bezier, .rectangle, .circle, .ellipse, .arc, .smooth => return constructPath(self, id, arg),
        .compound => {
            const combined = combined: {
                var result = Path.init(self.gpa);
                errdefer result.deinit();
                for (try sequence(arg.paths)) |item| {
                    if (item.valueType() != .path) {
                        self.native_message = "compound requires path elements";
                        return error.TypeMismatch;
                    }
                    try result.append(try self.path(item));
                }
                break :combined result;
            };
            return self.pathResult(combined);
        },
        .contour_ranges => {
            const ranges = try Path.contours.contourRanges(try self.path(arg.curve), self.gpa);
            defer self.gpa.free(ranges);
            const rows = try a.alloc(Value, ranges.len);
            for (rows, ranges) |*row, range| row.* = types.listView(try a.dupe(Value, &.{
                .{ .number = range.begin }, .{ .number = range.end }, .{ .boolean = range.closed },
            }));
            return types.listView(rows);
        },
        .subpaths => {
            const parts = try Path.contours.subpaths(try self.path(arg.curve), self.gpa);
            defer self.gpa.free(parts);
            var moved = false;
            defer if (!moved) for (parts) |*part| part.deinit();
            const values = try a.alloc(Value, parts.len);
            errdefer a.free(values);
            try conversions.pathResults(self, parts, values);
            moved = true;
            return types.listView(values);
        },
        .reverse, .closed => {
            if (arg.curve.valueType() == .shape)
                return conversions.modelResult(self, if (id == .reverse) .reverse else .closed, &.{arg.curve});
            if (id == .reverse) return self.pathResult(try (try self.path(arg.curve)).reverse(self.gpa));
            const closed = closed: {
                var result = try (try self.path(arg.curve)).clone(self.gpa);
                errdefer result.deinit();
                try result.close();
                break :closed result;
            };
            return self.pathResult(closed);
        },
        .joined => {
            if (arg.first.valueType() == .shape or arg.second.valueType() == .shape)
                return conversions.modelResult(self, .joined, &.{ arg.first, arg.second });
            const joined = joined: {
                var result = try (try self.path(arg.first)).clone(self.gpa);
                errdefer result.deinit();
                try Path.contours.join(&result, try self.path(arg.second));
                break :joined result;
            };
            return self.pathResult(joined);
        },
        .trimmed => return self.pathResult(try Path.trim.trimmed(try self.path(arg.curve), self.gpa, try numeric(arg.start), try numeric(arg.stop))),
        .clipped => return self.pathResult(try Path.trim.clippedToRect(try self.path(arg.curve), self.gpa, .{ .min = try point(arg.min), .max = try point(arg.max) })),
        .fillet => {
            const source = try self.path(arg.curve);
            var uniform: [1]f64 = undefined;
            const listed = types.sequence(arg.radii);
            const radii: []const f64 = if (listed) |values| try lengths(self.gpa, values) else blk: {
                uniform[0] = try lengthPoints(arg.radii);
                break :blk &uniform;
            };
            defer if (listed != null) self.gpa.free(radii);
            const rounded = path_fillet.fillet(self.gpa, source, radii) catch |err| {
                switch (err) {
                    error.InvalidRadii => self.native_message = "fillet radii must be finite, nonnegative, and one value or one per vertex",
                    error.OpenPath => self.native_message = "fillet requires a closed polygon",
                    error.CurvedSegment => self.native_message = "fillet requires line segments only",
                    error.MultipleContours => self.native_message = "fillet requires exactly one contour",
                    error.InvalidPath, error.TooFewVertices => self.native_message = "fillet requires a polygon with at least three vertices",
                    error.NonFinite => self.native_message = "fillet requires finite polygon coordinates",
                    error.RadiusTooLarge => self.native_message = "fillet radius is too large for adjacent edges",
                    error.DegeneratePolygon => self.native_message = "fillet requires a nondegenerate polygon",
                    error.DegenerateCorner => self.native_message = "fillet cannot round a vertex where an edge reverses onto the previous one",
                    else => {},
                }
                return err;
            };
            // Paths are immutable values: an unchanged polygon keeps its handle.
            return if (rounded) |result| self.pathResult(result) else arg.curve;
        },
        else => comptime unreachable,
    }
}

fn constructPath(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    const gpa = self.gpa;
    switch (id) {
        .circle => if (arg.center == .vec3) return conversions.modelResult(self, .circle, &.{ arg.center, arg.radius }),
        .ellipse => if (arg.center == .vec3) return conversions.modelResult(self, .ellipse, &.{ arg.center, arg.rx, arg.ry }),
        .arc => if (arg.center == .vec3) return conversions.modelResult(self, .arc, &.{ arg.center, arg.radius, arg.start, arg.sweep }),
        .bezier => if (arg.start == .vec3) return conversions.modelResult(self, .cubic, &.{ arg.start, arg.control1, arg.control2, arg.finish }),
        else => {},
    }
    const built = built: {
        // An empty path owns no memory until a segment is added, so a
        // constructor's result can replace it.
        var result = Path.init(gpa);
        errdefer result.deinit();
        switch (id) {
            .bezier => {
                try result.moveTo(try point(arg.start));
                try result.cubicTo(try point(arg.control1), try point(arg.control2), try point(arg.finish));
            },
            .rectangle => {
                const p = if (arg.origin == .vec3) g.Point.zero else try point(arg.origin);
                result = try Path.rectangle(gpa, p, try lengthPoints(arg.width), try lengthPoints(arg.height));
            },
            .circle => result = try Path.circle(gpa, try point(arg.center), try lengthPoints(arg.radius)),
            .ellipse => {
                const center = try point(arg.center);
                const rx = try lengthPoints(arg.rx);
                const ry = try lengthPoints(arg.ry);
                if (rx <= 0 or ry <= 0) return error.InvalidParameter;
                result = try Path.circle(gpa, .zero, 1);
                try result.transform(g.Transform.scaling(rx, ry).then(.translation(center.x, center.y)));
            },
            .arc => result = try Path.arcs.arc(gpa, try point(arg.center), try lengthPoints(arg.radius), try angular(arg.start), try angular(arg.sweep)),
            .smooth => {
                const values = try sequence(arg.points);
                const closed = if (arg.closed) |given| try boolean(given) else false;
                const knots = try gpa.alloc(hobby.Knot, values.len);
                defer gpa.free(knots);
                const tension = if (arg.tension) |given| try numeric(given) else 1;
                for (values, knots) |v, *k| k.* = .{ .point = try point(v), .incoming_tension = tension, .outgoing_tension = tension };
                result = try path_construct.fromKnots(gpa, knots, .{ .closed = closed });
            },
            else => unreachable,
        }
        break :built result;
    };
    // A spatial rectangle is the profile of a model; its path is stored too.
    if (id == .rectangle) if (arg.origin == .vec3) return conversions.modelResult(self, .profile, &.{
        try self.pathResult(built),               arg.origin,
        .{ .vec3 = .{ .x = 1, .y = 0, .z = 0 } }, .{ .vec3 = .{ .x = 0, .y = 1, .z = 0 } },
    });
    return self.pathResult(built);
}

/// `path` takes its points without parameter names: as separate values, or
/// as one list followed by whether it is closed and the joins between them.
pub fn pathFromPoints(self: *Runtime, args: []const Value) !Value {
    const gpa = self.gpa;
    const from_list = types.sequence(args[0]) != null;
    if (from_list and args.len > 3) return error.InvalidPath;
    const values = if (from_list) try sequence(args[0]) else args;
    const closed = if (from_list and hasArgument(args, 1)) try boolean(args[1]) else false;
    if (values.len != 0 and values[0] == .vec3) {
        if (values.len < 2) return error.TooFewKnots;
        for (values) |v| if (v != .vec3) return error.ExpectedVec3;
        if (from_list and hasArgument(args, 2)) {
            const joins = try sequence(args[2]);
            if (joins.len != values.len - @intFromBool(!closed)) return error.InvalidJoinCount;
            for (joins) |join| if (!std.mem.eql(u8, try string(join), "straight")) return error.HobbyRequiresPlanarPath;
        }
        return conversions.modelResult(self, if (closed) .polygon else .polyline, values);
    }
    const built = built: {
        // An empty path owns no memory until a segment is added, so a
        // constructor's result can replace it.
        var result = Path.init(gpa);
        errdefer result.deinit();
        if (from_list and hasArgument(args, 2)) {
            const kinds = try sequence(args[2]);
            const points = try gpa.alloc(g.Point, values.len);
            defer gpa.free(points);
            const joins = try gpa.alloc(path_construct.Join, kinds.len);
            defer gpa.free(joins);
            for (points, values) |*out, value| out.* = try point(value);
            for (joins, kinds) |*out, value| out.* = std.meta.stringToEnum(path_construct.Join, try string(value)) orelse return error.InvalidPathJoin;
            result = try path_construct.construct(gpa, points, joins, .{ .closed = closed });
        } else {
            if (values.len == 0) return error.InvalidPath;
            try result.moveTo(try point(values[0]));
            for (values[1..]) |v| try result.lineTo(try point(v));
            if (closed) try result.close();
        }
        break :built result;
    };
    return self.pathResult(built);
}
