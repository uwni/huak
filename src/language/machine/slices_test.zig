//! Tests of list slices.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Span = source.Span;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const lists = @import("lists.zig");
const templates = @import("templates.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;

test "list slices use inclusive range progression in both directions" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const values = types.listView(&.{ .{ .int = 0 }, .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 }, .{ .int = 5 } });
    const cases = [_]struct { start: i64, stop: ?i64, step: i64, expected: []const i64 }{
        .{ .start = 1, .stop = 3, .step = 1, .expected = &.{ 1, 2, 3 } },
        .{ .start = 0, .stop = 5, .step = 2, .expected = &.{ 0, 2, 4 } },
        .{ .start = 5, .stop = 0, .step = -2, .expected = &.{ 5, 3, 1 } },
        .{ .start = 3, .stop = 3, .step = std.math.minInt(i64), .expected = &.{3} },
        .{ .start = 2, .stop = std.math.maxInt(i64), .step = std.math.maxInt(i64), .expected = &.{2} },
        .{ .start = 4, .stop = 1, .step = 1, .expected = &.{} },
        .{ .start = 2, .stop = 4, .step = -1, .expected = &.{} },
        .{ .start = 3, .stop = null, .step = 1, .expected = &.{ 3, 4, 5 } },
        .{ .start = 6, .stop = null, .step = 1, .expected = &.{} },
        .{ .start = 0, .stop = 9, .step = 10, .expected = &.{0} },
    };
    for (cases) |case| {
        const result = try lists.sliceList(&machine, values, .{ .int = case.start }, if (case.stop) |stop| .{ .int = stop } else null, .{ .int = case.step });
        const items = types.sequence(result).?;
        try std.testing.expectEqual(case.expected.len, items.len);
        for (items, case.expected) |item, expected| try std.testing.expectEqual(expected, item.int);
    }
    const empty = try lists.sliceList(&machine, types.listView(&.{}), .{ .int = 0 }, null, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 0), empty.list.items().len);
    const empty_range = try lists.sliceList(&machine, types.listView(&.{}), .{ .int = 0 }, .{ .int = -1 }, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 0), empty_range.list.items().len);
    try std.testing.expect(empty.list.owned != empty_range.list.owned);
}

test "list slices reject invalid selected indices and validate empty range operands" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    const values = types.listView(&.{ .{ .int = 10 }, .{ .int = 20 } });
    const cases = [_]struct { start: Value, stop: ?Value, step: Value, message: []const u8 }{
        .{ .start = .{ .int = 1 }, .stop = .{ .int = 0 }, .step = .{ .int = 0 }, .message = "range step must not be zero" },
        .{ .start = .{ .int = -1 }, .stop = .{ .int = 0 }, .step = .{ .int = 1 }, .message = "index -1 is outside length 2" },
        .{ .start = .{ .int = 0 }, .stop = .{ .int = 2 }, .step = .{ .int = 1 }, .message = "index 2 is outside length 2" },
        .{ .start = .{ .int = -1 }, .stop = null, .step = .{ .int = 1 }, .message = "slice start -1 is outside length 2" },
        .{ .start = .{ .int = 3 }, .stop = null, .step = .{ .int = 1 }, .message = "slice start 3 is outside length 2" },
        .{ .start = .{ .int = 0 }, .stop = .unit, .step = .{ .int = 1 }, .message = "bounds and step must be int" },
        .{ .start = .{ .boolean = true }, .stop = .{ .int = 0 }, .step = .{ .int = 1 }, .message = "bounds and step must be int" },
        .{ .start = .{ .int = 1 }, .stop = .{ .number = 0 }, .step = .{ .int = 1 }, .message = "bounds and step must be int" },
        .{ .start = .{ .int = 1 }, .stop = .{ .int = 0 }, .step = .{ .number = 1 }, .message = "bounds and step must be int" },
    };
    for (cases) |case| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, lists.sliceList(&machine, values, case.start, case.stop, case.step));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), case.message) != null);
    }
    var wrong_object = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer wrong_object.deinit();
    try std.testing.expectError(error.RuntimeFailed, lists.sliceList(&wrong_object, .{ .int = 1 }, .{ .int = 0 }, null, .{ .int = 1 }));
    try std.testing.expectEqualStrings("slicing requires a list", wrong_object.failure.?.text());
}

test "explicit dynamically void slice endpoints are not treated as omitted" {
    const compiler = @import("../compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\fn missing()->any
            \\    return
            \\end
            \\xs:=[1,2]
            \\part:=xs[0:missing()]
        , "void-slice-endpoint.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqualStrings("list slice bounds and step must be int", machine.failure.?.text());
        try std.testing.expect(machine.getGlobal("part") == null);
    }
}

test "slice endpoint modes reject malformed bytecode before interpreting a sentinel" {
    const constants = [_]Value{ types.listView(&.{.{ .int = 1 }}), .{ .int = 0 }, .{ .int = 1 } };
    const codes = [_][]const I{
        &.{ins(.slice, 2)},
        &.{ ins(.constant, 0), ins(.constant, 1), ins(.constant, 1), ins(.constant, 2), ins(.slice, 1) },
    };
    for (codes) |code| {
        var program = try testProgram(&.{.{ .name = "script", .code = code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.startsWith(u8, machine.failure.?.text(), "invalid bytecode"));
    }
}

test "list slices create shallow containers and preserve selected template aliases and cycles" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const child: []const Value = &.{.{ .int = 1 }};
    const source_view = types.listView(&.{ types.listView(child), types.listView(child) });
    const source_owned = try templates.materialize(&machine, source_view);
    const shallow = try lists.sliceList(&machine, source_owned, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 });
    try std.testing.expect(shallow.list.owned != source_owned.list.owned);
    try lists.appendList(&machine, shallow, .{ .int = 3 });
    try std.testing.expectEqual(@as(usize, 2), source_owned.list.items().len);
    try std.testing.expectEqual(@as(usize, 3), shallow.list.items().len);
    try lists.appendList(&machine, shallow.list.items()[0], .{ .int = 2 });
    for (source_owned.list.items()) |row| try std.testing.expectEqual(@as(usize, 2), row.list.items().len);

    const selected = try lists.sliceList(&machine, source_view, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 });
    try std.testing.expect(selected.list.items()[0].list.owned == selected.list.items()[1].list.owned);
    try lists.appendList(&machine, selected.list.items()[0], .{ .int = 4 });
    try std.testing.expectEqual(@as(usize, 2), selected.list.items()[1].list.items().len);
    try std.testing.expectEqual(@as(usize, 1), child.len);
    const another = try lists.sliceList(&machine, source_view, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 1), another.list.items()[0].list.items().len);

    var cyclic: [1]Value = undefined;
    cyclic[0] = types.listView(&cyclic);
    const cycle_slice = try lists.sliceList(&machine, types.listView(&cyclic), .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 });
    const cycle = cycle_slice.list.items()[0];
    try std.testing.expect(cycle.list.owned != cycle_slice.list.owned);
    try std.testing.expect(cycle.list.items()[0].list.owned == cycle.list.owned);
}

test "worker slices own their container while nested borrowed lists stay protected" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var coordinator = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer coordinator.deinit();
    var worker = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer worker.deinit();
    const child = try lists.makeList(&coordinator, &.{.{ .int = 1 }});
    const input = try lists.makeList(&coordinator, &.{child});
    const result = try lists.sliceList(&worker, input, .{ .int = 0 }, null, .{ .int = 1 });
    try std.testing.expectEqual(worker.identity, result.list.owned.owner.?);
    try std.testing.expectEqual(coordinator.identity, result.list.items()[0].list.owned.owner);
    try lists.appendList(&worker, result, .{ .int = 2 });
    try std.testing.expectEqual(@as(usize, 1), input.list.items().len);
    try std.testing.expectError(error.RuntimeFailed, lists.appendList(&worker, result.list.items()[0], .{ .int = 3 }));
    try std.testing.expectEqual(@as(usize, 1), child.list.items().len);
}

test "slice element work respects the execution budget at the slice source position" {
    const span: Span = .{ .start = 20, .end = 26 };
    const constants = [_]Value{ types.listView(&.{ .{ .int = 0 }, .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } }), .{ .int = 0 }, .{ .int = 3 }, .{ .int = 1 } };
    const code = [_]I{ ins(.constant, 0), ins(.constant, 1), ins(.constant, 2), ins(.constant, 3), .{ .op = .slice, .span = span }, ins(.store_global, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{"result"}, &.{.list});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{ .instructions = 7 });
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(@as(u64, 7), machine.steps);
    try std.testing.expectEqual(span, machine.failure.?.diagnostic.span);
    try std.testing.expect(machine.getGlobal("result") == null);
    var complete = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer complete.deinit();
    _ = try complete.execute(&.{});
    try std.testing.expectEqual(@as(u64, code.len + 4), complete.steps);
    try std.testing.expectEqual(@as(usize, 4), complete.getGlobal("result").?.list.items().len);
}

fn sliceAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const result = machine.getGlobal("result").?;
    try std.testing.expectEqual(@as(usize, 2), result.list.items().len);
    try std.testing.expect(result.list.items()[0].list.owned == result.list.items()[1].list.owned);
}

test "slice allocation failures free partial results and template alias tracking" {
    const child: []const Value = &.{.{ .int = 1 }};
    const constants = [_]Value{ types.listView(&.{ types.listView(child), types.listView(child) }), .{ .int = 0 }, .{ .int = 1 }, .unit };
    const code = [_]I{ ins(.constant, 0), ins(.constant, 1), ins(.constant, 3), ins(.constant, 2), ins(.slice, 1), ins(.store_global, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{"result"}, &.{.list});
    defer program.deinit();
    try sliceAllocationExercise(std.testing.allocator, &program);
    // Backing resize can replace an allocation depending on heap placement.
    // Keep successful resizing covered above, and enumerate every allocation
    // failure with the same stable no-resize strategy as list append/builders.
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), sliceAllocationExercise, .{&program});
    try std.testing.expectEqual(@as(usize, 1), child.len);
}
