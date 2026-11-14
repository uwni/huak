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
/// A typ.module handle becomes the module at its position in `modules`, the
/// ascending module indices the request supplies. `huak` is bound when the
/// code reads a member or, with `whole`, uses it as a whole value; other code
/// has no `huak` to see.
pub fn encode(allocator: std.mem.Allocator, bindings: []const Machine.TypstBinding, colors: []const Color, modules: []const usize, whole: bool) ![]const c.TypstBinding {
    if (bindings.len == 0 and !whole) return &.{};
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
            .handle => |handle| if (handle.kind == .typst_module) {
                value.* = try moduleReference(handle.index, modules);
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
    // A module rather than a dictionary: Typst calls a module's function
    // members directly, as huak.mark(..), in markup and in math.
    const module = try allocator.create(c.TypstValueInput);
    module.* = std.mem.zeroes(c.TypstValueInput);
    module.kind = c.TYPST_VALUE_MODULE;
    module.text = .{ .data = "huak", .len = 4 };
    module.bindings = members.ptr;
    module.binding_count = members.len;
    const roots = try allocator.alloc(c.TypstBinding, 1);
    roots[0] = .{ .name = .{ .data = "huak", .len = 4 }, .value = module };
    return roots;
}

fn order(index: usize, item: usize) std.math.Order {
    return std.math.order(index, item);
}

/// The input that names the evaluated module at the handle's position in
/// `modules`.
fn moduleReference(index: usize, modules: []const usize) !c.TypstValueInput {
    const position = std.sort.binarySearch(usize, modules, index, order) orelse return error.InvalidTypstBinding;
    var value = std.mem.zeroes(c.TypstValueInput);
    value.kind = c.TYPST_VALUE_MODULE_HANDLE;
    value.integer = @intCast(position);
    return value;
}

/// Each show names a member of a module the request supplies, by the path
/// of member names separated by '.'. Borrowed like `encode`'s result.
pub fn encodeShows(allocator: std.mem.Allocator, shows: []const Machine.TypstShow, modules: []const usize) ![]const c.TypstShowValue {
    if (shows.len == 0) return &.{};
    const values = try allocator.alloc(c.TypstShowValue, shows.len);
    for (values, shows) |*value, show| {
        if (show.value != .handle or show.value.handle.kind != .typst_module or show.path.len == 0) return error.InvalidTypstBinding;
        const input = try allocator.create(c.TypstValueInput);
        input.* = try moduleReference(show.value.handle.index, modules);
        const path = try allocator.alloc(c.TypstStr, std.mem.count(u8, show.path, ".") + 1);
        var names = std.mem.splitScalar(u8, show.path, '.');
        for (path) |*name| {
            const member = names.next().?;
            if (member.len == 0) return error.InvalidTypstBinding;
            name.* = .{ .data = member.ptr, .len = member.len };
        }
        value.* = .{ .value = input, .path = path.ptr, .path_count = path.len };
    }
    return values;
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
                .{ .name = "style", .value = .{ .handle = .{ .kind = .typst_module, .index = 3 } } },
            };
            _ = try encode(scratch.allocator(), &snapshot, &.{.{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 0.25 }}, &.{3}, false);
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
        try std.testing.expectError(error.InvalidTypstBinding, encode(scratch.allocator(), &.{.{ .name = "container", .value = value }}, &.{}, &.{}, false));
    }
}

test "typ.module handles index the request's ascending modules" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const theme = [_]Machine.TypstBinding{.{ .name = "theme", .value = .{ .handle = .{ .kind = .typst_module, .index = 7 } } }};
    const roots = try encode(scratch.allocator(), &theme, &.{}, &.{ 2, 7, 9 }, false);
    const member = roots[0].value.*.bindings[0];
    try std.testing.expectEqual(@as(u32, c.TYPST_VALUE_MODULE_HANDLE), member.value.*.kind);
    try std.testing.expectEqual(@as(i64, 1), member.value.*.integer);
    try std.testing.expectError(error.InvalidTypstBinding, encode(scratch.allocator(), &theme, &.{}, &.{ 2, 9 }, false));
}

test "typ.show paths split into member names of a supplied module" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const module: @import("../types.zig").Value = .{ .handle = .{ .kind = .typst_module, .index = 9 } };
    const shows = try encodeShows(scratch.allocator(), &.{ .{ .value = module, .path = "style" }, .{ .value = module, .path = "page.style" } }, &.{ 2, 9 });
    try std.testing.expectEqual(@as(usize, 2), shows.len);
    for (shows, [_][]const []const u8{ &.{"style"}, &.{ "page", "style" } }) |show, names| {
        try std.testing.expectEqual(@as(u32, c.TYPST_VALUE_MODULE_HANDLE), show.value.*.kind);
        try std.testing.expectEqual(@as(i64, 1), show.value.*.integer);
        try std.testing.expectEqual(names.len, show.path_count);
        for (names, show.path[0..show.path_count]) |name, native_name| try std.testing.expectEqualStrings(name, native_name.data[0..native_name.len]);
    }
    for ([_][]const u8{ "", "page.", ".style", "a..b" }) |path| {
        try std.testing.expectError(error.InvalidTypstBinding, encodeShows(scratch.allocator(), &.{.{ .value = module, .path = path }}, &.{9}));
    }
    try std.testing.expectError(error.InvalidTypstBinding, encodeShows(scratch.allocator(), &.{.{ .value = module, .path = "style" }}, &.{2}));
    try std.testing.expectError(error.InvalidTypstBinding, encodeShows(scratch.allocator(), &.{.{ .value = .{ .int = 1 }, .path = "style" }}, &.{9}));
}

test "huak is bound without members only for code that uses it as a whole value" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try encode(scratch.allocator(), &.{}, &.{}, &.{}, false)).len);
    const roots = try encode(scratch.allocator(), &.{}, &.{}, &.{}, true);
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expectEqualStrings("huak", roots[0].name.data[0..roots[0].name.len]);
    try std.testing.expectEqual(@as(u32, c.TYPST_VALUE_MODULE), roots[0].value.*.kind);
    try std.testing.expectEqual(@as(usize, 0), roots[0].value.*.binding_count);
}
