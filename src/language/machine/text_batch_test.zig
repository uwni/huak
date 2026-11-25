//! Tests of batching adjacent text assignments.
const std = @import("std");
const units = @import("../../drawing/units.zig");
const bytecode = @import("../bytecode.zig");
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const testing = @import("testing.zig");
const TypstBatchProbe = testing.TypstBatchProbe;
const ins = testing.ins;
const testProgram = testing.testProgram;

test "adjacent text assignments batch until a result is observed" {
    const input =
        \\a:=typ[A]
        \\b:=typ[B]
        \\c:=typ[C]
        \\d:=typ[D]
        \\width:=c.width
        \\e:=typ[E]
        \\f:=typ[F]
        \\print(width)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 0), probe.single_calls);
        try std.testing.expectEqualSlices(usize, &.{ 4, 2 }, probe.batch_sizes[0..probe.batch_count]);
        try std.testing.expectEqual(@as(usize, 1), probe.fields);
        try std.testing.expectEqual(@as(usize, 1), probe.effects);
        try std.testing.expectEqual(units.fromPoints(3), machine.getGlobal("width").?.quantity);
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        _ = try serial.execute(&.{});
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqual(serial_probe.seen_count, probe.seen_count);
    }
}

test "text batching supports locals and treats function calls as barriers" {
    var program = try TypstBatchProbe.compile(
        \\fn make() -> text
        \\ local_a:=typ[Local A]
        \\ local_b:=typ[Local B]
        \\ return local_b
        \\end
        \\a:=typ[A]
        \\b:=typ[B]
        \\result:=make()
        \\c:=typ[C]
        \\d:=typ[D]
    , true);
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, probe.batch_sizes[0..probe.batch_count]);
    try std.testing.expectEqual(@as(usize, 3), machine.getGlobal("result").?.handle.index);
    try std.testing.expectEqual(@as(usize, 0), machine.locals.items.len);
}

test "text batch failures preserve successful bindings source positions and effects" {
    const input =
        \\first:=typ[First]
        \\second:=typ[FAIL first error]
        \\third:=typ[FAIL later error]
        \\print("must not execute")
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqual(@as(usize, 1), probe.batch_count);
        try std.testing.expect(machine.getGlobal("first") != null);
        try std.testing.expect(machine.getGlobal("second") == null);
        try std.testing.expect(machine.getGlobal("third") == null);
        try std.testing.expectEqual(@as(usize, 0), probe.effects);
        try std.testing.expectEqual(std.mem.indexOf(u8, input, "typ[FAIL first").?, machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqualStrings(probe.seen[1], machine.failure.?.native_message);
        @memset(&probe.message_storage, '?');
        try std.testing.expectEqualStrings(probe.seen[1], machine.failure.?.native_message);
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        try std.testing.expectError(error.RuntimeFailed, serial.execute(&.{}));
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualDeep(serial.initialized, machine.initialized);
        try std.testing.expectEqual(serial.failure.?.diagnostic.span, machine.failure.?.diagnostic.span);
    }
}

test "text batch planning preserves instruction limits without speculative requests" {
    var program = try TypstBatchProbe.compile(
        \\a:=typ[A]
        \\b:=typ[B]
        \\c:=typ[C]
        \\print("complete")
    , true);
    defer program.deinit();
    for (0..12) |limit| {
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{ .instructions = limit });
        defer machine.deinit();
        const actual = machine.execute(&.{});
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{ .instructions = limit });
        defer serial.deinit();
        const expected = serial.execute(&.{});
        if (expected) |value| {
            try std.testing.expectEqualDeep(value, try actual);
        } else |err| try std.testing.expectError(err, actual);
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualDeep(serial.initialized, machine.initialized);
        try std.testing.expectEqual(serial_probe.seen_count, probe.seen_count);
        try std.testing.expectEqual(serial_probe.effects, probe.effects);
        if (serial.failure) |failure| try std.testing.expectEqual(failure.diagnostic.span, machine.failure.?.diagnostic.span);
    }
}

test "text batching has a bounded descriptor budget" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    for (0..130) |index| try writer.writer.print("text_{d}:=typ[Label {d}]\n", .{ index, index });
    var program = try TypstBatchProbe.compile(writer.written(), true);
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(usize, &.{ 64, 64, 2 }, probe.batch_sizes[0..probe.batch_count]);
    try std.testing.expectEqual(@as(usize, 130), probe.seen_count);
    try std.testing.expectEqual(@as(usize, 129), machine.getGlobal("text_129").?.handle.index);
}

test "fatal text batch failures locate their request without a recoverable prefix" {
    const input =
        \\first:=typ[First]
        \\second:=typ[Second]
        \\third:=typ[Third]
        \\print("must not execute")
    ;
    var program = try TypstBatchProbe.compile(input, true);
    defer program.deinit();
    var probe: TypstBatchProbe = .{ .fatal_index = 2 };
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "typ[Third]").?, machine.failure.?.diagnostic.span.start);
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "TypstPanic") != null);
    try std.testing.expectEqual(@as(u64, 5), machine.steps);
    try std.testing.expect(machine.getGlobal("first") == null);
    try std.testing.expectEqual(@as(usize, 0), probe.effects);
    var invalid_probe: TypstBatchProbe = .{ .fatal_index = 3 };
    var invalid = try Machine.init(std.testing.allocator, &program, invalid_probe.host(true), .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, invalid.failure.?.text(), "invalid Typst batch failure index") != null);
}

test "text batch planning preserves malformed bytecode error order" {
    for (0..3) |kind| {
        var code = [_]I{
            .{ .op = .typst, .a = 0, .span = .{ .start = 10, .end = 11 } },
            .{ .op = .store_global, .a = 0, .span = .{ .start = 12, .end = 13 } },
            .{ .op = .typst, .a = 1, .span = .{ .start = 20, .end = 21 } },
            .{ .op = .store_global, .a = 1, .span = .{ .start = 22, .end = 23 } },
            .{ .op = .typst, .a = 2, .span = .{ .start = 30, .end = 31 } },
            .{ .op = .store_global, .a = 2, .span = .{ .start = 32, .end = 33 } },
            ins(.halt, 0),
        };
        var readonly = [_]bool{ false, false, false };
        switch (kind) {
            0 => code[4].a = 100,
            1 => code[5].a = 100,
            2 => readonly[2] = true,
            else => unreachable,
        }
        var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .string = "A" }, .{ .string = "B" }, .{ .string = "C" } }, &.{ "a", "b", "c" }, &.{ .text, .text, .text });
        defer program.deinit();
        program.readonly_globals = &readonly;
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        try std.testing.expectError(error.RuntimeFailed, serial.execute(&.{}));
        try std.testing.expectEqual(@as(usize, 1), probe.batch_count);
        try std.testing.expectEqual(serial_probe.seen_count, probe.seen_count);
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqual(serial.failure.?.diagnostic.span, machine.failure.?.diagnostic.span);
        try std.testing.expectEqualStrings(serial.failure.?.text(), machine.failure.?.text());
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualDeep(serial.initialized, machine.initialized);
        try std.testing.expectEqualDeep(serial.stack.items, machine.stack.items);
    }
}

test "text batching honors entry jumps and repeated target assignments" {
    const code = [_]I{
        ins(.jump, 3),         ins(.typst, 0),        ins(.store_global, 0),
        ins(.typst, 1),        ins(.store_global, 1), ins(.typst, 2),
        ins(.store_global, 1), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .string = "Skipped" }, .{ .string = "A" }, .{ .string = "B" } }, &.{ "skipped", "result" }, &.{ .text, .text });
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(usize, &.{2}, probe.batch_sizes[0..probe.batch_count]);
    try std.testing.expect(machine.getGlobal("skipped") == null);
    try std.testing.expectEqual(@as(usize, 1), machine.getGlobal("result").?.handle.index);
    try std.testing.expectEqual(@as(u64, 6), machine.steps);
}
