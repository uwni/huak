//! Formatting values, and the builtins print, int, float and str.
const std = @import("std");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Type = types.Type;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const number = conversions.number;
const numeric = conversions.numeric;

/// Printing and the conversions int, float and str.
pub fn invoke(self: *Runtime, a: std.mem.Allocator, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .print => {
            if (self.task_borrow != null) return error.TaskSideEffect;
            const message = try formatValue(a, arg.value);
            try self.printed.appendSlice(self.gpa, message);
            try self.printed.append(self.gpa, '\n');
            return .unit;
        },
        .to_int => return .{ .int = switch (arg.value) {
            .int => |v| v,
            .number => |v| blk: {
                if (!std.math.isFinite(v) or v < -0x1p63 or v >= 0x1p63) return error.IntegerOverflow;
                break :blk @intFromFloat(v);
            },
            .string => |v| try std.fmt.parseInt(i64, v, 10),
            else => return error.TypeMismatch,
        } },
        .to_number => return number(switch (arg.value) {
            .string => |v| try std.fmt.parseFloat(f64, v),
            else => try numeric(arg.value),
        }),
        .to_string => return .{ .string = try formatValue(a, arg.value) },
        else => comptime unreachable,
    }
}

pub const FormatError = std.mem.Allocator.Error || error{ ValueNestingTooDeep, ValueFormattingLimit, InvalidValue };

const SequenceIdentity = struct { address: usize, len: usize = 0, kind: enum { list, dict, record } = .list };

/// Bound native work performed by one VM instruction. Lists may share nested
/// values, so a small input graph can otherwise expand into unbounded output.
pub fn formatValue(a: std.mem.Allocator, value: Value) FormatError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var remaining: usize = 100_000;
    var ancestors: [257]?SequenceIdentity = @splat(null);
    try appendValue(a, &result, value, 0, &remaining, &ancestors);
    return result.toOwnedSlice(a);
}

test "aggregate runtime formatting marks mixed cycles and preserves dictionary order" {
    const a = std.testing.allocator;
    var dict: types.Dict = .{};
    defer dict.entries.deinit(a);
    var fields = [_]Value{.{ .dict = &dict }};
    var record_value: types.Record = .{ .kind = Type.record(0), .fields = &fields };
    try dict.entries.put(a, "tag", .{ .int = 1 });
    try dict.entries.put(a, "cycle", .{ .record = &record_value });
    const rendered = try formatValue(a, .{ .dict = &dict });
    defer a.free(rendered);
    try std.testing.expectEqualStrings("{\"tag\": 1, \"cycle\": struct{{...}}}", rendered);
    try std.testing.expectError(error.InvalidValue, formatValue(a, .omitted));
    var escaped: types.Dict = .{};
    defer escaped.entries.deinit(a);
    try escaped.entries.put(a, "quote\"\\\n", .unit);
    const quoted = try formatValue(a, .{ .dict = &escaped });
    defer a.free(quoted);
    try std.testing.expectEqualStrings("{\"quote\\\"\\\\\\n\": ()}", quoted);
}

test "aggregate runtime formatting enforces the existing graph budget and releases allocations" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator, value: Value) !void {
            const text = try formatValue(allocator, value);
            defer allocator.free(text);
        }
    };
    var dict: types.Dict = .{};
    defer dict.entries.deinit(std.testing.allocator);
    try dict.entries.put(std.testing.allocator, "self", .{ .dict = &dict });
    try dict.entries.put(std.testing.allocator, "list", types.listView(&.{ .{ .int = 1 }, .{ .int = 2 } }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{Value{ .dict = &dict }});
    var doubled: [20][2]Value = undefined;
    for (&doubled, 0..) |*level, index| level.* = if (index == 0) .{ .unit, .unit } else .{ types.listView(&doubled[index - 1]), types.listView(&doubled[index - 1]) };
    try std.testing.expectError(error.ValueFormattingLimit, formatValue(std.testing.allocator, types.listView(&doubled[doubled.len - 1])));
}

test "list formatting preserves contents and marks cycles without exposing identity" {
    const a = std.testing.allocator;
    var identity: types.Ownership = .{};
    var cyclic: types.List.Owned = .{ .owner = &identity };
    defer cyclic.values.deinit(a);
    try cyclic.values.append(a, .{ .list = .{ .owned = &cyclic } });
    const rendered = try formatValue(a, .{ .list = .{ .owned = &cyclic } });
    defer a.free(rendered);
    try std.testing.expectEqualStrings("[[...]]", rendered);
    var view: [1]Value = undefined;
    view[0] = types.listView(&view);
    const borrowed = try formatValue(a, types.listView(&view));
    defer a.free(borrowed);
    try std.testing.expectEqualStrings(rendered, borrowed);
}

fn appendBytes(a: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8) FormatError!void {
    const limit = 8 * 1024 * 1024;
    if (bytes.len > limit - output.items.len) return error.ValueFormattingLimit;
    try output.appendSlice(a, bytes);
}

fn appendQuoted(a: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) FormatError!void {
    try appendBytes(a, output, "\"");
    var begin: usize = 0;
    for (text, 0..) |character, index| {
        const escaped: ?[]const u8 = switch (character) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escaped) |bytes| {
            try appendBytes(a, output, text[begin..index]);
            try appendBytes(a, output, bytes);
            begin = index + 1;
        }
    }
    try appendBytes(a, output, text[begin..]);
    try appendBytes(a, output, "\"");
}

fn appendValue(a: std.mem.Allocator, output: *std.ArrayList(u8), value: Value, depth: usize, remaining: *usize, ancestors: *[257]?SequenceIdentity) FormatError!void {
    if (depth > 256) return error.ValueNestingTooDeep;
    if (remaining.* == 0) return error.ValueFormattingLimit;
    remaining.* -= 1;
    var buffer: [4096]u8 = undefined;
    switch (value) {
        .list => |list| {
            const items = list.items();
            for (ancestors[0..depth]) |previous| if (previous) |identity| {
                if (identity.kind == .list and identity.address == @intFromPtr(items.ptr) and identity.len == items.len) return appendBytes(a, output, "[...]");
            };
            ancestors[depth] = .{ .address = @intFromPtr(items.ptr), .len = items.len };
            defer ancestors[depth] = null;
            try appendBytes(a, output, "[");
            for (items, 0..) |item, index| {
                if (index != 0) try appendBytes(a, output, ", ");
                try appendValue(a, output, item, depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, "]");
        },
        .dict => |dict| {
            for (ancestors[0..depth]) |previous| if (previous) |identity| {
                if (identity.kind == .dict and identity.address == @intFromPtr(dict)) return appendBytes(a, output, "{...}");
            };
            ancestors[depth] = .{ .address = @intFromPtr(dict), .kind = .dict };
            defer ancestors[depth] = null;
            try appendBytes(a, output, "{");
            for (dict.entries.keys(), dict.entries.values(), 0..) |key, item, index| {
                if (index != 0) try appendBytes(a, output, ", ");
                try appendQuoted(a, output, key);
                try appendBytes(a, output, ": ");
                try appendValue(a, output, item, depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, "}");
        },
        .record => |record_value| {
            for (ancestors[0..depth]) |previous| if (previous) |identity| {
                if (identity.kind == .record and identity.address == @intFromPtr(record_value)) return appendBytes(a, output, "struct{...}");
            };
            ancestors[depth] = .{ .address = @intFromPtr(record_value), .kind = .record };
            defer ancestors[depth] = null;
            try appendBytes(a, output, "struct{");
            for (record_value.fields, 0..) |item, index| {
                if (index != 0) try appendBytes(a, output, ", ");
                try appendValue(a, output, item, depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, "}");
        },
        .unit => try appendBytes(a, output, "()"),
        .omitted => return error.InvalidValue,
        .boolean => |x| try appendBytes(a, output, if (x) "true" else "false"),
        .string => |x| try appendBytes(a, output, x),
        .int => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "{d}", .{x}) catch return error.ValueFormattingLimit),
        .number => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "{d}", .{x}) catch return error.ValueFormattingLimit),
        .quantity => |x| {
            try appendBytes(a, output, std.fmt.bufPrint(&buffer, "{d}", .{x.value}) catch return error.ValueFormattingLimit);
            if (x.dimension.length != 0) {
                try appendBytes(a, output, "mm");
                if (x.dimension.length != 1) try appendBytes(a, output, std.fmt.bufPrint(&buffer, "^{d}", .{x.dimension.length}) catch return error.ValueFormattingLimit);
            }
            if (x.dimension.angle != 0) {
                if (x.dimension.length != 0) try appendBytes(a, output, " ");
                try appendBytes(a, output, "rad");
                if (x.dimension.angle != 1) try appendBytes(a, output, std.fmt.bufPrint(&buffer, "^{d}", .{x.dimension.angle}) catch return error.ValueFormattingLimit);
            }
        },
        inline .vec2, .vec3 => |x| {
            try appendBytes(a, output, "(");
            try appendValue(a, output, x.component(x.x), depth + 1, remaining, ancestors);
            try appendBytes(a, output, ", ");
            try appendValue(a, output, x.component(x.y), depth + 1, remaining, ancestors);
            if (@hasField(@TypeOf(x), "z")) {
                try appendBytes(a, output, ", ");
                try appendValue(a, output, x.component(x.z), depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, ")");
        },
        .function => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "<function:{s}:{d}>", .{ @tagName(x), switch (x) {
            .bytecode, .native => |i| i,
            .bound => |bound| switch (bound.target) {
                .bytecode, .native => |i| i,
            },
        } }) catch return error.ValueFormattingLimit),
        .object => try appendBytes(a, output, "<object>"),
        .handle => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "<{s}:{d}>", .{ x.kind.name(), x.index }) catch return error.ValueFormattingLimit),
    }
}
