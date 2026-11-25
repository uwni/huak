//! Builtins for coverage regions, boolean operations, offsets, width-based stroke outlines and rectangle clipping.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const pen_geometry = @import("../../drawing/pen/root.zig");
const regions = @import("../../drawing/region/root.zig");
const region_geometry = @import("../../drawing/region/coverage.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const outlines = @import("outlines.zig");
const conversions = @import("conversions.zig");
const builtin_calls = @import("builtin_calls.zig");
const sequence = conversions.sequence;
const numeric = conversions.numeric;
const lengths = conversions.lengths;
const string = conversions.string;
const lengthPoints = conversions.lengthPoints;
const point = conversions.point;

/// Coverage regions, boolean operations, offsets, width-based stroke outlines and rectangle clipping.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .profile_outline => {
            const position_values = try sequence(arg.left);
            const width_values = try sequence(arg.right);
            if (position_values.len != width_values.len) return error.InvalidProfile;
            const positions = try self.gpa.alloc(f64, position_values.len);
            defer self.gpa.free(positions);
            for (positions, position_values) |*out, value| out.* = try numeric(value);
            const widths = try lengths(self.gpa, width_values);
            defer self.gpa.free(widths);
            var options: regions.Options = .{};
            if (arg.cap) |cap| options.cap = std.meta.stringToEnum(regions.Cap, try string(cap)) orelse return error.InvalidCap;
            if (arg.join) |join| options.join = std.meta.stringToEnum(regions.Join, try string(join)) orelse return error.InvalidJoin;
            if (arg.miter_limit) |limit| options.miter_limit = try numeric(limit);
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            return self.pathResult(try pen_geometry.profileOutline(self.gpa, try self.path(arg.curve), positions, widths, options));
        },
        .region => {
            var options: regions.Options = .{};
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) {
                self.native_message = "region tolerance must be positive";
                return error.InvalidTolerance;
            }
            var vector_picture = try outlines.vectorPicture(self, self.gpa, arg.object, .region);
            defer vector_picture.deinit();
            return self.pathResult(try region_geometry.extract(self.gpa, &vector_picture, options));
        },
        .region_union, .region_intersection, .region_difference, .region_xor => {
            if (arg.first.valueType() == .shape or arg.second.valueType() == .shape) {
                if (arg.tolerance != null or arg.fill_rule != null or arg.first.valueType() != .shape or arg.second.valueType() != .shape) return error.ExpectedTwoModelShapes;
                return conversions.modelResult(self, switch (id) {
                    .region_union => .fuse,
                    .region_intersection => .common,
                    .region_difference => .cut,
                    else => return error.UnsupportedModelOperation,
                }, &.{ arg.first, arg.second });
            }
            var options: regions.Options = .{};
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            if (arg.fill_rule) |rule| options.fill_rule = std.meta.stringToEnum(regions.FillRule, try string(rule)) orelse return error.InvalidFillRule;
            const operation: regions.Operation = switch (id) {
                .region_union => .unite,
                .region_intersection => .intersect,
                .region_difference => .difference,
                .region_xor => .xor,
                else => unreachable,
            };
            return self.pathResult(try regions.combine(self.gpa, try self.path(arg.first), try self.path(arg.second), operation, options));
        },
        .offset => {
            var options: regions.Options = .{};
            if (arg.join) |join| options.join = std.meta.stringToEnum(regions.Join, try string(join)) orelse return error.InvalidJoin;
            if (arg.miter_limit) |limit| options.miter_limit = try numeric(limit);
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            if (arg.fill_rule) |rule| options.fill_rule = std.meta.stringToEnum(regions.FillRule, try string(rule)) orelse return error.InvalidFillRule;
            return self.pathResult(try regions.offset(self.gpa, try self.path(arg.curve), try lengthPoints(arg.distance), options));
        },
        .stroke_path => {
            var options: regions.Options = .{};
            if (arg.cap) |cap| options.cap = std.meta.stringToEnum(regions.Cap, try string(cap)) orelse return error.InvalidCap;
            if (arg.join) |join| options.join = std.meta.stringToEnum(regions.Join, try string(join)) orelse return error.InvalidJoin;
            if (arg.miter_limit) |limit| options.miter_limit = try numeric(limit);
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            return self.pathResult(try regions.stroke(self.gpa, try self.path(arg.curve), try lengthPoints(arg.width), options));
        },
        .clip_region, .clip_lines => {
            var options: regions.Options = .{};
            if (arg.tolerance) |given| options.tolerance = try lengthPoints(given);
            if (id == .clip_region) if (arg.fill_rule) |rule| {
                options.fill_rule = std.meta.stringToEnum(regions.FillRule, try string(rule)) orelse return error.InvalidFillRule;
            };
            const source = try self.path(arg.curve);
            const rect: g.BBox = .{ .min = try point(arg.min), .max = try point(arg.max) };
            return self.pathResult(if (id == .clip_region) try regions.clipRegion(self.gpa, source, rect, options) else try regions.clipLines(self.gpa, source, rect, options));
        },
        else => comptime unreachable,
    }
}

test "region clipping fill rule preserves the hole between nested same-direction contours" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const outer = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .{ .x = 0, .y = 0 } }, .{ .number = 10 }, .{ .number = 10 } });
    const inner = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .{ .x = 2, .y = 2 } }, .{ .number = 6 }, .{ .number = 6 } });
    const compound = compound: {
        var result = try (try runtime.path(outer)).clone(runtime.gpa);
        errdefer result.deinit();
        try result.append(try runtime.path(inner));
        break :compound result;
    };
    const nested = try runtime.pathResult(compound);
    const min: Value = .{ .vec2 = .{ .x = -1, .y = -1 } };
    const max: Value = .{ .vec2 = .{ .x = 11, .y = 11 } };
    const solid = try builtin_calls.invoke(&runtime, a, .clip_region, &.{ nested, min, max });
    const ring = try builtin_calls.invoke(&runtime, a, .clip_region, &.{ nested, min, max, .{ .number = 0.001 }, .{ .string = "evenodd" } });
    var solid_contours: usize = 0;
    for ((try runtime.path(solid)).segments.items) |segment| {
        if (segment == .close) solid_contours += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), solid_contours);
    var contours: usize = 0;
    var holes: usize = 0;
    var area: f64 = 0;
    var contour_area: f64 = 0;
    var first = g.Point.zero;
    var previous = g.Point.zero;
    for ((try runtime.path(ring)).segments.items) |segment| switch (segment) {
        .move => |p| {
            first = p;
            previous = p;
            contour_area = 0;
        },
        .line => |p| {
            contour_area += previous.cross(p);
            previous = p;
        },
        .close => {
            contour_area += previous.cross(first);
            area += contour_area * 0.5;
            contours += 1;
            if (contour_area < 0) holes += 1;
        },
        .cubic => return error.UnexpectedCurve,
    };
    try std.testing.expectEqual(@as(usize, 2), contours);
    try std.testing.expectEqual(@as(usize, 1), holes);
    try std.testing.expectApproxEqAbs(@as(f64, 64), area, 1e-7);
}
