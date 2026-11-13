//! Huak value snapshots represented as generic borrowed libtypst inputs.
//! The namespace policy stays here; native value conversion belongs to libtypst.
const std = @import("std");
const native = @import("libtypst");
const Machine = @import("../Machine.zig");
const units = @import("../../drawing/units.zig");
const Color = @import("../../drawing/DisplayList.zig").Color;
const c = native.c;

/// Every record and string is borrowed until the native layout call returns.
/// Allocate the tree in that call's scratch arena, never the VM lifetime arena.
/// A show_rule handle becomes the template at its position in `rules`, the
/// ascending rule indices the request supplies as templates.
pub fn encode(allocator: std.mem.Allocator, bindings: []const Machine.TypstBinding, colors: []const Color, rules: []const usize) ![]const c.TypstBinding {
    if (bindings.len == 0) return &.{};
    const values = try allocator.alloc(c.TypstValueInput, bindings.len);
    const members = try allocator.alloc(c.TypstBinding, bindings.len);
    for (bindings, values, members) |binding, *value, *member| {
        if (binding.name.len == 0 or !std.unicode.utf8ValidateSlice(binding.name)) return error.InvalidTypstBinding;
        value.* = std.mem.zeroes(c.TypstValueInput);
        switch (binding.value) {
            .int => |number| {
                value.kind = c.TYPST_VALUE_INT;
                value.integer = number;
            },
            .number => |number| {
                if (!std.math.isFinite(number)) return error.InvalidTypstBinding;
                value.kind = c.TYPST_VALUE_FLOAT;
                value.number = number;
            },
            .boolean => |boolean| {
                value.kind = c.TYPST_VALUE_BOOL;
                value.integer = @intFromBool(boolean);
            },
            .string => |string| {
                if (!std.unicode.utf8ValidateSlice(string)) return error.InvalidTypstBinding;
                value.kind = c.TYPST_VALUE_STRING;
                value.text = .{ .data = string.ptr, .len = string.len };
            },
            .quantity => |quantity| {
                if (!quantity.dimension.eql(.distance)) return error.InvalidTypstBinding;
                value.kind = c.TYPST_VALUE_LENGTH;
                value.number = try units.toPoints(quantity);
            },
            .handle => |handle| if (handle.kind == .show_rule) {
                const position = std.sort.binarySearch(usize, rules, handle.index, order) orelse return error.InvalidTypstBinding;
                value.kind = c.TYPST_VALUE_TEMPLATE;
                value.integer = @intCast(position);
            } else {
                if (handle.kind != .color or handle.index >= colors.len) return error.InvalidTypstBinding;
                const color = colors[handle.index];
                if (!color.valid()) return error.InvalidTypstBinding;
                value.kind = c.TYPST_VALUE_COLOR;
                value.color = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
            },
            else => return error.InvalidTypstBinding,
        }
        member.* = .{ .name = .{ .data = binding.name.ptr, .len = binding.name.len }, .value = value };
    }
    const dictionary = try allocator.create(c.TypstValueInput);
    dictionary.* = std.mem.zeroes(c.TypstValueInput);
    dictionary.kind = c.TYPST_VALUE_DICT;
    dictionary.bindings = members.ptr;
    dictionary.binding_count = members.len;
    const roots = try allocator.alloc(c.TypstBinding, 1);
    roots[0] = .{ .name = .{ .data = "huak", .len = 4 }, .value = dictionary };
    return roots;
}

fn order(index: usize, item: usize) std.math.Order {
    return std.math.order(index, item);
}

test "Typst snapshot tree scratch ownership is released on every allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var scratch: std.heap.ArenaAllocator = .init(allocator);
            defer scratch.deinit();
            const snapshot = [_]Machine.TypstBinding{
                .{ .name = "count", .value = .{ .int = std.math.minInt(i64) } },
                .{ .name = "title", .value = .{ .string = "literal \" #panic(\"never\") Ω" } },
                .{ .name = "size", .value = .{ .quantity = units.fromPoints(12) } },
                .{ .name = "ink", .value = .{ .handle = .{ .kind = .color, .index = 0 } } },
                .{ .name = "style", .value = .{ .handle = .{ .kind = .show_rule, .index = 3 } } },
            };
            _ = try encode(scratch.allocator(), &snapshot, &.{.{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 0.25 }}, &.{3});
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "aggregate runtime Typst bindings reject script containers and omitted slots" {
    const types = @import("../types.zig");
    var dict: types.Dict = .{};
    var record_value: types.Record = .{ .kind = types.Type.record(0), .fields = &.{} };
    for ([_]types.Value{ .{ .dict = &dict }, .{ .record = &record_value }, types.listView(&.{}), .omitted }) |value| {
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        try std.testing.expectError(error.InvalidTypstBinding, encode(scratch.allocator(), &.{.{ .name = "container", .value = value }}, &.{}, &.{}));
    }
}

test "show rule handles index the request's ascending rule templates" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const rule = [_]Machine.TypstBinding{.{ .name = "style", .value = .{ .handle = .{ .kind = .show_rule, .index = 7 } } }};
    const roots = try encode(scratch.allocator(), &rule, &.{}, &.{ 2, 7, 9 });
    const member = roots[0].value.*.bindings[0];
    try std.testing.expectEqual(@as(u32, c.TYPST_VALUE_TEMPLATE), member.value.*.kind);
    try std.testing.expectEqual(@as(i64, 1), member.value.*.integer);
    try std.testing.expectError(error.InvalidTypstBinding, encode(scratch.allocator(), &rule, &.{}, &.{ 2, 9 }));
}
