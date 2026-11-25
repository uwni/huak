//! The for loop over lists and numeric ranges.
const std = @import("std");
const numeric = @import("../numeric.zig");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const templates = @import("templates.zig");
const failures = @import("failures.zig");
const validation = @import("validation.zig");
const operators = @import("operators.zig");
const Error = Machine.Error;

/// Starts a `for` loop over a numeric range or a list.
pub fn iterateInit(self: *Machine, instruction: bytecode.Instruction) Error!void {
    const values: [3]Value = if (instruction.a == 0) range: {
        const step = try self.pop();
        const stop = try self.pop();
        const start = try self.pop();
        break :range try initializeRange(self, start, stop, step);
    } else collection: {
        const value = try self.pop();
        if (value != .list) return self.fail("for requires a list or numeric range", .{});
        break :collection .{ .{ .int = 0 }, value, .{ .int = @bitCast(@as(u64, value.list.items().len)) } };
    };
    for (values) |value| try self.push(value);
}

/// Tests whether a `for` loop has another value, and pushes it.
pub fn iterateTest(self: *Machine) Error!void {
    const step = try self.pop();
    const stop = try self.pop();
    const current = try self.pop();
    const more = if (stop == .list) try listIterationTest(self, current, stop, step) else try rangeTest(self, current, stop, step);
    const value: Value = if (!more) .unit else switch (stop) {
        .list => |list| try templates.materialize(self, list.items()[@intCast(current.int)]),
        else => current,
    };
    try self.push(value);
    try self.push(.{ .boolean = more });
}

/// Advances a `for` loop.
pub fn iterateAdvance(self: *Machine) Error!void {
    const step = try self.pop();
    const stop = try self.pop();
    const current = try self.pop();
    const next = if (stop == .list) collection: {
        _ = try listIterationTest(self, current, stop, step);
        const next: Value = .{ .int = current.int + 1 };
        break :collection RangeProgress{ .value = next, .more = try listIterationTest(self, next, stop, step) };
    } else try rangeAdvance(self, current, stop, step);
    try self.push(next.value);
    try self.push(.{ .boolean = next.more });
}

fn listIterationTest(self: *Machine, current: Value, collection: Value, step: Value) Error!bool {
    if (current != .int or current.int < 0 or step != .int) return self.fail("invalid iterator state", .{});
    if (collection.list.items().len != @as(u64, @bitCast(step.int))) return self.fail("collection structure changed during iteration", .{});
    const length = collection.list.items().len;
    return @as(u64, @intCast(current.int)) < length;
}

pub fn initializeRange(self: *Machine, start: Value, stop: Value, step: Value) Error![3]Value {
    if (start == .quantity or stop == .quantity or step == .quantity) {
        const dimension = if (start == .quantity) start.quantity.dimension else if (stop == .quantity) stop.quantity.dimension else step.quantity.dimension;
        var values = [_]Value{ start, stop, step };
        for (&values) |*value| {
            var quantity = types.asQuantity(value.*) catch return self.fail("range bounds and step must be numeric", .{});
            if (quantity.dimension.eql(.scalar) and quantity.value == 0) quantity.dimension = dimension;
            if (!quantity.dimension.eql(dimension)) return self.fail("range bounds and step require compatible dimensions", .{});
            _ = quantity.checked() catch |err| return failures.numericFailure(self, err);
            value.* = types.fromQuantity(quantity);
        }
        if ((types.asQuantity(values[2]) catch unreachable).value == 0) return self.fail("range step must not be zero", .{});
        return values;
    }
    // Validate even an empty range before its first comparison or body.
    _ = try validation.number(self, start);
    _ = try validation.number(self, stop);
    if (try validation.number(self, step) == 0) return self.fail("range step must not be zero", .{});
    if (start == .number or stop == .number or step == .number) {
        return .{ try validation.coerce(self, start, .number), try validation.coerce(self, stop, .number), try validation.coerce(self, step, .number) };
    }
    return .{ start, stop, step };
}

pub fn rangeTest(self: *Machine, current: Value, stop: Value, step: Value) Error!bool {
    const direction = (types.asQuantity(step) catch return self.fail("range step must be numeric", .{})).value;
    if (direction == 0) return self.fail("range step must not be zero", .{});
    try validation.checkFinite(self, current);
    try validation.checkFinite(self, stop);
    const order = try operators.compare(self, current, stop);
    return if (direction > 0) order != .gt else order != .lt;
}

const RangeProgress = struct { value: Value, more: bool };

pub fn rangeAdvance(self: *Machine, current: Value, stop: Value, step: Value) Error!RangeProgress {
    const finished: RangeProgress = .{ .value = current, .more = false };
    if (!try rangeTest(self, current, stop, step) or try operators.compare(self, current, stop) == .eq) return finished;
    const next: Value = if (current == .int and step == .int) blk: {
        const result = @addWithOverflow(current.int, step.int);
        // A monotonic range has passed its finite stop when the next
        // integer cannot be represented; this is normal loop completion.
        if (result[1] != 0) return finished;
        break :blk .{ .int = result[0] };
    } else if (current == .quantity) blk: {
        const sum = numeric.valueArithmetic(.add, current, step) catch |err| {
            if (err == error.NonFinite) return finished;
            return failures.numericFailure(self, err);
        };
        break :blk sum;
    } else blk: {
        const sum = try validation.number(self, current) + try validation.number(self, step);
        if (!std.math.isFinite(sum)) return finished;
        break :blk .{ .number = sum };
    };
    if (try operators.compare(self, next, current) == .eq) return self.fail("range step is too small to advance the current value", .{});
    return if (try rangeTest(self, next, stop, step)) .{ .value = next, .more = true } else finished;
}

test "list iteration and dictionary key snapshots share loop control and evaluate once" {
    const compiler = @import("../compiler.zig");
    const input =
        \\calls:=[]
        \\fn items()->list calls+=1; return [1,2,3,4] end
        \\sum:=0
        \\for item in items() do
        \\    if item==2 then continue end
        \\    if item==4 then break end
        \\    sum=sum+item
        \\    item=100
        \\end
        \\empty:=0
        \\for unused in [] do empty=empty+1 end
        \\dict:={"first": 1,"second": 2}
        \\seen:=[]
        \\for key in dict.keys() do
        \\    seen+=[key]
        \\    dict_remove(dict,key)
        \\    dict["added"]=3
        \\end
        \\values:=[1,2,3]
        \\updated:=0
        \\for item in values do
        \\    values[2]=10
        \\    updated=updated+item
        \\end
        \\nested:=0
        \\for row in [[1,2],[3,4]] do
        \\    for value in row do nested=nested+value end
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "iterables.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 1), machine.getGlobal("calls").?.list.items().len);
        try std.testing.expectEqual(@as(i64, 4), machine.getGlobal("sum").?.int);
        try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("empty").?.int);
        try std.testing.expectEqual(@as(i64, 13), machine.getGlobal("updated").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("nested").?.int);
        const seen = machine.getGlobal("seen").?.list.items();
        try std.testing.expectEqual(@as(usize, 2), seen.len);
        try std.testing.expectEqualStrings("first", seen[0].string);
        try std.testing.expectEqualStrings("second", seen[1].string);
        try std.testing.expectEqual(@as(usize, 1), machine.getGlobal("dict").?.dict.entries.count());
    }
    for ([_][]const u8{ "items:=[1];for x in items do items+=2 end", "values:=[{}];for x in values[0] do end" }) |invalid| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, invalid, "invalid-iterable.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
    var diagnostic: ?source.Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compiler.compile(std.testing.allocator, "for key in {} do end", "dictionary.huak", .{}, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "for requires a list or numeric range") != null);
}
