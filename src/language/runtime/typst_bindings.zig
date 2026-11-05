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
pub fn encode(allocator: std.mem.Allocator, bindings: []const Machine.TypstBinding, colors: []const Color) ![]const c.TypstBinding {
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
            .handle => |handle| {
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
            };
            _ = try encode(scratch.allocator(), &snapshot, &.{.{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 0.25 }});
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
        try std.testing.expectError(error.InvalidTypstBinding, encode(scratch.allocator(), &.{.{ .name = "container", .value = value }}, &.{}));
    }
}
