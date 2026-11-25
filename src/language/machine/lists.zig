//! Lists: construction, appends and slices.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const templates = @import("templates.zig");
const validation = @import("validation.zig");
const iteration = @import("iteration.zig");
const Error = Machine.Error;
const SequenceKey = templates.SequenceKey;

/// Slices a list by a range, open-ended when the instruction says so.
pub fn slice(self: *Machine, instruction: bytecode.Instruction) Error!void {
    if (instruction.a > 1) return self.fail("invalid bytecode slice endpoint mode", .{});
    const step = try self.pop();
    const stop = try self.pop();
    const start = try self.pop();
    const object = try self.pop();
    if (instruction.a == 1 and stop != .unit) return self.fail("invalid bytecode open slice endpoint", .{});
    try self.push(try sliceList(self, object, start, if (instruction.a == 1) null else stop, step));
}

pub fn mutableList(self: *Machine, value: Value) Error!*std.ArrayList(Value) {
    if (value != .list) return self.fail("expected a list", .{});
    if (value.list != .owned) return self.fail("cannot modify a borrowed list view", .{});
    if (value.list.owned.owner != self.identity) return self.fail("cannot modify a borrowed task list", .{});
    return &value.list.owned.values;
}

pub fn makeList(self: *Machine, items: []const Value) Error!Value {
    // Validate before assigning our owner. Internal copies can then rely
    // on this invariant; every mutation validates its new references.
    try checkFiniteItems(self, items);
    const value = try allocateList(self, items);
    value.list.owned.owner = self.identity;
    return value;
}

pub fn prepareListItems(self: *Machine, items: []Value) Error!void {
    // A later materialization failure must still precede validation of an
    // earlier item. Shallow copies use checkFiniteItems without this step.
    for (items) |*item| item.* = try templates.materialize(self, item.*);
    try checkFiniteItems(self, items);
}

fn checkFiniteItems(self: *Machine, items: []const Value) Error!void {
    for (items) |item| try validation.checkFinite(self, item);
}

/// Graph construction has no owner until every cyclic node has
/// been filled. No partially initialized node can take the fast path.
pub fn allocateList(self: *Machine, items: []const Value) Error!Value {
    const list = try self.arena.allocator().create(types.List.Owned);
    list.* = .{};
    try list.values.appendSlice(self.arena.allocator(), items);
    return .{ .list = .{ .owned = list } };
}

pub fn listIndex(self: *Machine, index: i64, length: usize) Error!usize {
    if (index < 0 or @as(u64, @intCast(index)) >= length)
        return self.fail("list index {d} is outside length {d}", .{ index, length });
    return @intCast(index);
}

pub fn sliceList(self: *Machine, object: Value, start: Value, stop: ?Value, step: Value) Error!Value {
    const items = types.sequence(object) orelse return self.fail("slicing requires a list", .{});
    if (start != .int or step != .int or (stop != null and stop.? != .int))
        return self.fail("list slice bounds and step must be int", .{});
    const end = stop orelse blk: {
        const length = std.math.cast(i64, items.len) orelse return self.fail("list length exceeds the index range", .{});
        if (start.int < 0 or start.int > length)
            return self.fail("list slice start {d} is outside length {d}", .{ start.int, items.len });
        break :blk Value{ .int = length - 1 };
    };
    const range = try iteration.initializeRange(self, start, end, step);
    const result = try allocateList(self, &.{});
    // Import selected template elements together so repeated and cyclic
    // children retain their aliases without copying an unselected prefix.
    var seen: std.AutoHashMapUnmanaged(SequenceKey, Value) = .empty;
    defer seen.deinit(self.gpa);
    var current = range[0];
    while (try iteration.rangeTest(self, current, range[1], range[2])) {
        // One instruction cannot bypass the execution budget by selecting
        // an arbitrarily large list. Charge each selected element.
        try self.tick();
        const index = try listIndex(self, current.int, items.len);
        try validation.checkFinite(self, items[index]);
        const value = try templates.materializeGraph(self, items[index], &seen, 0);
        try result.list.owned.values.append(self.arena.allocator(), value);
        const next = try iteration.rangeAdvance(self, current, range[1], range[2]);
        if (!next.more) break;
        current = next.value;
    }
    templates.finishGraph(self, &seen);
    result.list.owned.owner = self.identity;
    return result;
}

pub fn appendList(self: *Machine, target: Value, input: Value) Error!void {
    const list = try mutableList(self, target);
    // Appending exposes nested elements through a mutable script list.
    // Import the complete graph once, retaining its internal aliases.
    const value = try templates.materialize(self, input);
    try validation.checkFinite(self, value);
    if (value.valueType() == .list) {
        const other = types.sequence(value) orelse return self.fail("expected a list", .{});
        if (value.list == .owned and target.list.owned == value.list.owned) {
            const count = list.items.len;
            try list.ensureUnusedCapacity(self.arena.allocator(), count);
            // Reserve first: the old prefix may have moved during growth.
            list.appendSliceAssumeCapacity(list.items[0..count]);
        } else try list.appendSlice(self.arena.allocator(), other);
    } else try list.append(self.arena.allocator(), value);
}

pub fn appendListItems(self: *Machine, instruction: bytecode.Instruction) Error!void {
    self.current_span.start = instruction.b;
    const items = try self.arguments(instruction.a);
    try prepareListItems(self, items);
    self.current_span = instruction.span;
    const start = self.stack.items.len - items.len;
    const base = self.frames.items[self.frames.items.len - 1].stack_base;
    if (start <= base) return self.fail("invalid bytecode operand stack underflow", .{});
    const target = self.stack.items[start - 1];
    self.stack.items.len = start - 1;
    const list = try mutableList(self, target);
    try list.appendSlice(self.arena.allocator(), items);
}
