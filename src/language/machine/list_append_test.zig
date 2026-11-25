//! Tests of list append.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Machine = @import("../Machine.zig");
const lists = @import("lists.zig");

fn listAppendAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const before = types.sequence(machine.getGlobal("before").?).?;
    const after = types.sequence(machine.getGlobal("after").?).?;
    try std.testing.expectEqual(@as(usize, 12), before.len);
    try std.testing.expectEqual(@as(usize, 26), after.len);
    try std.testing.expectEqual(@as(i64, 26), machine.getGlobal("alias_count").?.int);
    try std.testing.expectEqualSlices(u8, "tail", after[25].string);
    try std.testing.expectEqual(@as(usize, 2), types.sequence(after[24]).?.len);
    for (after[0..12], after[12..24]) |first, second| try std.testing.expectEqualDeep(first, second);
    const source_values = types.sequence(machine.getGlobal("source").?).?;
    try std.testing.expectEqual(@as(usize, 2), source_values.len);
    try std.testing.expectEqual(@as(i64, 3), source_values[0].int);
}

test "list append preserves aliases snapshots and self append through allocation failures" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\values:=[1,2]
        \\other:=[3,4]
        \\alias:=values
        \\for i in 1:5 do alias+=other end
        \\before:=[];before+=values
        \\values+=alias
        \\values+=[[7,8]]
        \\values+="tail"
        \\source:=[];source+=other
        \\after:=[];after+=values
        \\alias_count:=len(alias)
    , "list-append-allocation.huak", .{}, &diagnostic);
    defer program.deinit();
    try listAppendAllocationExercise(std.testing.allocator, &program);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), listAppendAllocationExercise, .{&program});
}

test "list append checks dynamic targets before mutating a collection" {
    const compiler = @import("../compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, "values:any:=42;values+=1", "invalid-list-append.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "expected a list") != null);
        try std.testing.expectEqual(@as(i64, 42), machine.getGlobal("values").?.int);
    }
}

fn listItemsAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const items = machine.getGlobal("items").?.list.owned;
    const nested = machine.getGlobal("nested").?.list.owned;
    try std.testing.expectEqual(@as(usize, 5), items.values.items.len);
    try std.testing.expect(items == machine.getGlobal("alias").?.list.owned);
    try std.testing.expectEqual(@as(i64, 1), items.values.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), items.values.items[1].int);
    try std.testing.expect(items.values.items[2].list.owned == nested);
    try std.testing.expect(items.values.items[3].record.fields[0].list.owned == nested);
    try std.testing.expect(items.values.items[4].list.owned == items);
    try std.testing.expectEqual(@as(usize, 2), nested.values.items.len);
}

test "list literal append retains empty multi-item nested any and self aliases through allocation failures" {
    const compiler = @import("../compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\struct Entry
            \\    value:any
            \\end
            \\fn insert(dst:list, value:any) dst += [value] end
            \\items:=[]
            \\items+=[]
            \\items+=[1,2]
            \\nested:=[9]
            \\insert(items,nested)
            \\items+=[Entry(value:nested)]
            \\alias:=items
            \\items+=[items]
            \\nested+=10
        , "list-items.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var combined: usize = 0;
        for (program.functions) |function| for (function.code) |instruction| {
            if (instruction.op == .list_append_items) combined += 1;
        };
        try std.testing.expect(if (optimize) combined != 0 else combined == 0);
        try listItemsAllocationExercise(std.testing.allocator, &program);
        var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(stable.allocator(), listItemsAllocationExercise, .{&program});
    }
}

test "compiled literal append handles branches loops and grouped span fallback" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\items:=[]
        \\for i in 1:4 do
        \\    if i > 1 then items += [i] end
        \\end
        \\items += ([5])
    , "literal-append-spans.huak", .{}, &diagnostic);
    defer program.deinit();
    var combined: usize = 0;
    var separate: usize = 0;
    for (program.functions) |function| for (function.code) |instruction| {
        if (instruction.op == .list_append_items) {
            combined += 1;
            try std.testing.expectEqualStrings("[i]", program.source_text[instruction.b..instruction.span.end]);
        }
        if (instruction.op == .list_append) separate += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), combined);
    try std.testing.expectEqual(@as(usize, 1), separate);
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const items = machine.getGlobal("items").?.list.items();
    try std.testing.expectEqual(@as(usize, 4), items.len);
    for (items, 2..) |item, expected| try std.testing.expectEqual(@as(i64, @intCast(expected)), item.int);
}

test "list append resolves handles after RHS growth and preserves preceding RHS effects" {
    const compiler = @import("../compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\values:=[1]
            \\fn grown(target:list)->list
            \\    for i in 1:64 do scratch:=[i] end
            \\    target+=2
            \\    return [3,4]
            \\end
            \\values+=grown(values)
            \\empty:=[]
            \\empty+=empty
            \\values+=empty
            \\snapshot:=[];snapshot+=values
            \\values+=5
        , "list-rhs-growth.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const snapshot = types.sequence(machine.getGlobal("snapshot").?).?;
        try std.testing.expectEqual(@as(usize, 4), snapshot.len);
        for (snapshot, 1..) |value, expected| try std.testing.expectEqual(@as(i64, @intCast(expected)), value.int);

        var failing_program = try compiler.compile(std.testing.allocator,
            \\values:=[1]
            \\fn failing(target:list)->int
            \\    target+=2
            \\    return 1%0
            \\end
            \\values+=failing(values)
        , "list-rhs-error.huak", .{ .optimize = optimize }, &diagnostic);
        defer failing_program.deinit();
        var failing = try Machine.init(std.testing.allocator, &failing_program, .{}, .{});
        defer failing.deinit();
        try std.testing.expectError(error.RuntimeFailed, failing.execute(&.{}));
        const remaining = try lists.mutableList(&failing, failing.getGlobal("values").?);
        try std.testing.expectEqual(@as(usize, 2), remaining.items.len);
        try std.testing.expectEqual(@as(i64, 2), remaining.items[1].int);
        try std.testing.expect(std.mem.indexOf(u8, failing.failure.?.text(), "division by zero") != null);
    }
}
