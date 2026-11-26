//! Reading builtin arguments and building results: numbers, lengths, angles, vectors, strings, sequences, and typed access to the registries.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const pen_geometry = @import("../../drawing/pen/root.zig");
const types = @import("../types.zig");
const units = types.units;
const numeric_ops = @import("../numeric.zig");
const builtin = @import("../builtin.zig");
const testOwner = @import("testing.zig").testOwner;
const Value = types.Value;
const Type = types.Type;
const Model = @import("model.zig");
const Runtime = @import("../Runtime.zig");
const builtin_calls = @import("builtin_calls.zig");
const transforms = @import("transforms.zig");
const object_handles = @import("object_handles.zig");
const typeset_text = @import("typeset_text.zig");
const Text = typeset_text.Text;

/// Optional builtin parameters may have compiler-inserted holes after named
/// arguments are reordered. An explicit unit remains a supplied value.
pub fn hasArgument(args: []const Value, index: usize) bool {
    return index < args.len and args[index] != .omitted;
}

/// Appends a value whose memory, if any, the caller still releases on failure.
pub fn store(self: *Runtime, comptime T: type, list: *std.ArrayList(T), value: T, kind: Type) !Value {
    const index = list.items.len;
    try list.append(self.gpa, value);
    return handle(kind, index);
}

pub fn color(self: *Runtime, value: Value) !DisplayList.Color {
    return self.colors.items[try checkedIndex(value, .color, self.colors.items.len)];
}

pub fn penValue(self: *Runtime, value: Value) !DisplayList.Pen {
    return self.pens.items[try checkedIndex(value, .pen, self.pens.items.len)];
}

pub fn gradientValue(self: *Runtime, value: Value) !*const DisplayList.Gradient {
    return self.gradients.items[try checkedIndex(value, .gradient, self.gradients.items.len)];
}

/// A color or a gradient, as what paints a fill or a stroke.
pub fn paint(self: *Runtime, value: Value) !DisplayList.Paint {
    if (value == .handle and value.handle.kind == .gradient) return .{ .gradient = try gradientValue(self, value) };
    return .{ .color = try color(self, value) };
}

/// The value of a paint: its color, or its gradient.
pub fn paintResult(self: *Runtime, value: DisplayList.Paint) !Value {
    return switch (value) {
        .color => |c| store(self, DisplayList.Color, &self.colors, c, .color),
        .gradient => |gradient| storeGradient(self, gradient.*),
    };
}

/// Stores a copy of a gradient with arrays of its own (or shared through the
/// runtime's mesh store); pens and paints refer to it while the runtime lives.
pub fn storeGradient(self: *Runtime, value: DisplayList.Gradient) !Value {
    const owned = try self.gpa.create(DisplayList.Gradient);
    errdefer self.gpa.destroy(owned);
    owned.* = try value.clone(self.gpa, self.backends.meshes);
    errdefer owned.deinit(self.gpa);
    const index = self.gradients.items.len;
    try self.gradients.append(self.gpa, owned);
    return handle(.gradient, index);
}

/// Stores an already-owned/adopted gradient without cloning its arrays.
/// On failure, the caller still owns `value`.
pub fn adoptGradient(self: *Runtime, value: DisplayList.Gradient) !Value {
    const owned = try self.gpa.create(DisplayList.Gradient);
    errdefer self.gpa.destroy(owned);
    owned.* = value;
    const index = self.gradients.items.len;
    try self.gradients.append(self.gpa, owned);
    return handle(.gradient, index);
}

pub fn transformValue(self: *Runtime, value: Value) !g.Transform {
    return switch (try self.affineValue(value)) {
        .plane => |t| t.xy,
        .spatial => error.ExpectedPlanarTransform,
    };
}

pub fn modelResult(self: *Runtime, kind: Model.Kind, args: []const Value) !Value {
    for (args) |value| switch (value) {
        .int, .number, .quantity, .vec2, .vec3 => {},
        .handle => |ref| switch (ref.kind) {
            .path, .shape, .transform => {},
            else => return error.InvalidModelArgument,
        },
        else => return error.InvalidModelArgument,
    };
    const arguments = try self.gpa.dupe(Value, args);
    errdefer self.gpa.free(arguments);
    return store(self, Model.Node, &self.models, .{ .kind = kind, .arguments = arguments }, .shape);
}

pub fn textValue(self: *Runtime, value: Value) !Text {
    return self.texts.items[try checkedIndex(value, .text, self.texts.items.len)];
}

/// Moves every path into the registry, or none: on failure the caller still
/// owns them all.
pub fn pathResults(self: *Runtime, paths: []const Path, values: []Value) !void {
    try self.path_values.ensureUnusedCapacity(self.gpa, paths.len);
    for (paths, values) |item, *value| {
        value.* = handle(.path, self.path_values.items.len);
        self.path_values.appendAssumeCapacity(item);
    }
}

pub fn handle(kind: Type, id: usize) Value {
    return .{ .handle = .{ .kind = kind, .index = id } };
}

pub fn checkedIndex(v: Value, kind: Type, count: usize) !usize {
    if (v != .handle or v.handle.kind != kind or v.handle.index >= count) return error.TypeMismatch;
    return v.handle.index;
}

pub fn numeric(v: Value) !f64 {
    return switch (v) {
        .int => |x| @floatFromInt(x),
        .number => |x| x,
        else => error.TypeMismatch,
    };
}

pub fn number(v: f64) !Value {
    if (!std.math.isFinite(v)) return error.NonFinite;
    return .{ .number = v };
}

pub fn lengthResult(v: f64) !Value {
    if (!std.math.isFinite(v)) return error.NonFinite;
    return .{ .quantity = units.fromPoints(v) };
}

pub fn lengthPoints(v: Value) !f64 {
    return if (v == .quantity) units.toPoints(v.quantity) else numeric(v);
}

/// Native points for a list of lengths, in one allocation owned by the caller.
pub fn lengths(allocator: std.mem.Allocator, values: []const Value) ![]f64 {
    const result = try allocator.alloc(f64, values.len);
    errdefer allocator.free(result);
    for (values, result) |value, *out| out.* = try lengthPoints(value);
    return result;
}

pub fn angular(v: Value) !f64 {
    if (v == .quantity) {
        if (!v.quantity.dimension.eql(.rotation)) return error.DimensionMismatch;
        _ = try v.quantity.checked();
        return v.quantity.value;
    }
    return numeric(v);
}

pub fn vector(v: Value) !types.Vec2 {
    return if (v == .vec2 and v.vec2.isFinite()) v.vec2 else error.TypeMismatch;
}

pub fn point(v: Value) !g.Point {
    return switch (v) {
        .vec2 => |p| p.nativePoint(),
        else => error.TypeMismatch,
    };
}

pub fn boolean(v: Value) !bool {
    return switch (v) {
        .boolean => |x| x,
        else => error.TypeMismatch,
    };
}

pub fn string(v: Value) ![]const u8 {
    return switch (v) {
        .string => |x| x,
        else => error.TypeMismatch,
    };
}

pub fn sequence(v: Value) ![]const Value {
    return types.sequence(v) orelse error.TypeMismatch;
}

test "native geometry converts physical lengths while vector arithmetic retains dimensions" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const cm: Value = .{ .quantity = try units.applyUnit(1, .cm) };
    const centre = try numeric_ops.makeVec2(cm, .{ .int = 0 });
    const canvas = try builtin_calls.invoke(&runtime, a, .picture, &.{ cm, cm });
    try std.testing.expectApproxEqAbs(@as(f64, 720.0 / 25.4), (try testOwner(canvas).scene.settings(canvas.object.index)).size.?.x, 1e-12);
    const curve = try builtin_calls.invoke(&runtime, a, .circle, &.{ centre, cm });
    const result = (try runtime.path(curve)).bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 1440.0 / 25.4), result.max.x, 1e-12);
    const unit = try builtin_calls.invoke(&runtime, a, .unit, &.{centre});
    try std.testing.expect(unit.vec2.dimension.eql(.scalar));
    try std.testing.expectApproxEqAbs(@as(f64, 1), unit.vec2.x, 1e-12);
    const norm = try builtin_calls.invoke(&runtime, a, .norm, &.{centre});
    try std.testing.expectEqual(cm.quantity, norm.quantity);
    const dot = try builtin_calls.invoke(&runtime, a, .dot, &.{ centre, centre });
    try std.testing.expectEqual(units.Dimension{ .length = 2 }, dot.quantity.dimension);
    const sqrt = try builtin_calls.invoke(&runtime, a, .sqrt, &.{dot});
    try std.testing.expectEqual(cm.quantity, sqrt.quantity);
    const radians = try builtin_calls.invoke(&runtime, a, .atan2, &.{ cm, cm });
    try std.testing.expect(radians.quantity.dimension.eql(.rotation));
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 4.0), radians.quantity.value, 1e-12);
    const midpoint = try builtin_calls.invoke(&runtime, a, .lerp, &.{ cm, .{ .quantity = try units.applyUnit(2, .cm) }, .{ .number = 0.5 } });
    try std.testing.expectEqual(@as(f64, 15), midpoint.quantity.value);
    try std.testing.expectError(error.DimensionMismatch, builtin_calls.invoke(&runtime, a, .min, &.{ cm, radians }));
    try std.testing.expectError(error.DimensionMismatch, builtin_calls.invoke(&runtime, a, .rotate, &.{cm}));
}

test "aggregate runtime sparse optional builtin slots retain host defaults" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const red = try builtin_calls.invoke(&runtime, a, .rgb, &.{ .{ .int = 1 }, .{ .int = 0 }, .{ .int = 0 }, .omitted });
    try std.testing.expectEqual(@as(f64, 1), (try color(&runtime, red)).a);
    const default_pen = try penValue(&runtime, try builtin_calls.invoke(&runtime, a, .pen, &.{red}));
    const brush = try penValue(&runtime, try builtin_calls.invoke(&runtime, a, .pen, &.{ red, .omitted, .omitted, .{ .string = "round" }, .omitted, .omitted, .omitted, .omitted }));
    try std.testing.expectEqual(default_pen.width, brush.width);
    try std.testing.expectEqual(default_pen.cap, brush.cap);
    try std.testing.expectEqual(default_pen.miter_limit, brush.miter_limit);
    try std.testing.expectEqual(DisplayList.Join.round, brush.join);
    const first_stop = types.listView(&.{ .{ .int = 0 }, .{ .int = 2 } });
    const last_stop = types.listView(&.{ .{ .int = 1 }, .{ .int = 12 } });
    var profile_args = [_]Value{ red, .omitted, .omitted, .omitted, .omitted, .omitted, .omitted, .omitted, types.listView(&.{ first_stop, last_stop }) };
    const pressure = try penValue(&runtime, try builtin_calls.invoke(&runtime, a, .pen, &profile_args));
    try std.testing.expectEqual(@as(f64, 12), pressure.motion.?.keys[1].value);
    profile_args[8] = types.listView(&.{ first_stop, first_stop, last_stop });
    try std.testing.expectError(error.InvalidProfile, builtin_calls.invoke(&runtime, a, .pen, &profile_args));
    profile_args[8] = types.listView(&.{ first_stop, last_stop });
    profile_args[5] = types.listView(&.{.{ .int = 3 }});
    try std.testing.expectError(error.InvalidPen, builtin_calls.invoke(&runtime, a, .pen, &profile_args));
    const circle = try penValue(&runtime, try builtin_calls.invoke(&runtime, a, .pencircle, &.{ .omitted, red }));
    try std.testing.expectEqual(DisplayList.Paint{ .color = .{ .r = 1, .g = 0, .b = 0 } }, circle.paint);
    try std.testing.expectEqual(g.Transform{}, circle.nib.?.ellipse);
    const square = try penValue(&runtime, try builtin_calls.invoke(&runtime, a, .pensquare, &.{ .omitted, red }));
    try std.testing.expectEqualSlices(g.Point, pen_geometry.Nib.square().polygon, square.nib.?.polygon);
    const scale = try transformValue(&runtime, try builtin_calls.invoke(&runtime, a, .scale, &.{ .{ .int = 3 }, .omitted }));
    try std.testing.expectEqual(g.Transform.scaling(3, 3), scale);
    try std.testing.expectError(error.InvalidCanvas, builtin_calls.invoke(&runtime, a, .picture, &.{ .omitted, .{ .int = 123 } }));
    const target = try builtin_calls.invoke(&runtime, a, .picture, &.{ .{ .int = 640 }, .{ .int = 123 }, .omitted, .omitted });
    try std.testing.expectEqual(@as(f64, 640), (try testOwner(target).scene.settings(target.object.index)).size.?.x);
    try std.testing.expectEqual(@as(f64, 123), (try testOwner(target).scene.settings(target.object.index)).size.?.y);
    const curve = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const shifted = try transforms.transformResult(&runtime, .translation(5, 6), 1);
    const item = try builtin_calls.invoke(&runtime, a, .append, &.{ target, try builtin_calls.invoke(&runtime, a, .draw, &.{ curve, .omitted, shifted }) });
    const instance = try object_handles.objectValue(&runtime, item, false);
    const command = (try instance.owner.scene.getNode(instance.index)).path;
    try std.testing.expectEqual(g.Transform.translation(5, 6), command.transform);
    try std.testing.expectEqualDeep(DisplayList.Pen{}, command.style.pen.?);
    try std.testing.expectError(error.TypeMismatch, builtin_calls.invoke(&runtime, a, .scale, &.{ .{ .int = 3 }, .unit }));
    for ([_]builtin.Id{ .dict_contains, .dict_remove, .dict_keys }) |id| try std.testing.expectError(error.InvalidBuiltin, builtin_calls.invoke(&runtime, a, id, &.{}));
}
