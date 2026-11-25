//! Bytecode builders shared by the propagation tests.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Allocator = std.mem.Allocator;
const Value = bc.Value;
const t = std.testing;

pub fn ins(op: bc.Op, a: u32) bc.Instruction {
    return .{ .op = op, .a = a };
}

pub fn pool(a: Allocator, items: []const Value) !std.array_list.Managed(Value) {
    var result = std.array_list.Managed(Value).init(a);
    errdefer result.deinit();
    try result.appendSlice(items);
    return result;
}

pub fn expectInt(code: []const bc.Instruction, constants: []const Value, ip: usize, expected: i64) !void {
    try t.expectEqual(bc.Op.constant, code[ip].op);
    try t.expectEqual(expected, constants[code[ip].a].int);
}
