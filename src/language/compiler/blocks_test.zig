//! Tests of block values, expanded blocks, drawing targets, lowered control flow and conditional declarations.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Value = bc.Value;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const compile = compilation.compile;

test "block values keep lexical bindings and return to the nearest block" {
    const input =
        \\a := 2
        \\value := block
        \\    a := 1
        \\    b := block; return 2; end
        \\    return a + b
        \\end
        \\fn compute() -> int
        \\    x := 10 + block
        \\        for i in 1:4 do
        \\            if i == 2 then; return i; end
        \\        end
        \\        return 0
        \\    end
        \\    return x + 1
        \\end
        \\result := compute()
        \\sum := 0
        \\for i in 1:4 do
        \\    x := block
        \\        if i == 2 then; continue; end
        \\        if i == 4 then; break; end
        \\        return i
        \\    end
        \\    sum = sum + x
        \\end
        \\empty := block; x := 1; end
        \\shadow := block
        \\    a := block; return a+1; end
        \\    return a
        \\end
        \\fn combine(a:int, b:int) -> int; return a+b; end
        \\mixfix(combine) combine _ with _ in unary
        \\continued := block
        \\    a := combine 10
        \\        with a
        \\    return a
        \\end
        \\for i in 1:2 do
        \\    a := a+1
        \\    sum = sum+a
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "block-values.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        inline for (.{ "a", "value", "result", "sum", "shadow", "continued" }, .{ 2, 3, 13, 10, 3, 12 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        try std.testing.expectEqual(Value.unit, machine.getGlobal("empty").?);
        try std.testing.expect(machine.getGlobal("b") == null);
    }
}

test "expanded blocks bind arguments once and expose local commands without captures" {
    const input =
        \\fn put(target:dict, value:int)
        \\    target["sum"] = target["sum"] + value
        \\end
        \\fn next(target:dict) -> dict
        \\    target["calls"] = target["calls"] + 1
        \\    return target
        \\end
        \\expand_block accumulate(target:dict)
        \\    place := put.with(target: target)
        \\    mixfix(place) place _ in unary
        \\    ...
        \\    target["finished"] = target["finished"] + 1
        \\    return target["sum"]
        \\end
        \\state := {"sum":0,"calls":0,"finished":0}
        \\first := accumulate next(state) do
        \\    place 3
        \\    place(4)
        \\end
        \\second := accumulate(state) do
        \\    place 2
        \\    return 99
        \\end
        \\third := accumulate state do; end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = compile(std.testing.allocator, input, "expanded.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s} at {d}\n", .{ detail.text(), detail.span.start });
            return err;
        };
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = machine.execute(&.{}) catch |err| {
            if (machine.failure) |failure| std.debug.print("{s}\n", .{failure.diagnostic.text()});
            return err;
        };
        inline for (.{ "first", "second", "third" }, .{ 7, 99, 9 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        const state = machine.getGlobal("state").?.dict;
        try std.testing.expectEqual(@as(i64, 1), state.entries.get("calls").?.int);
        try std.testing.expectEqual(@as(i64, 2), state.entries.get("finished").?.int);
    }
    for ([_][]const u8{
        "expand_block invalid(); end",
        "expand_block invalid(); ...; ...; end",
        "expand_block invalid(); ...; block ... end; end",
        "expand_block scope(); import math.abs; ...; end; scope do abs:=1 end",
    }) |invalid| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, invalid, "invalid-block.huak", .{}, &diagnostic));
    }
}

test "dynamic drawing picture targets retain typed runtime validation" {
    var diagnostic: ?Diagnostic = null;
    var valid = try compile(std.testing.allocator, "expand_block drawing(target:picture); ...; return target; end\npictures:=[picture(640, 480)]\ndrawing pictures[0] do end", "dynamic-picture.huak", .{}, &diagnostic);
    defer valid.deinit();
    try std.testing.expectEqual(Type.picture, valid.functions[valid.entry].local_types[0]);
    var invalid = try compile(std.testing.allocator, "expand_block drawing(target:picture); ...; return target; end\ndrawing [3][0] do end", "invalid-dynamic-picture.huak", .{}, &diagnostic);
    defer invalid.deinit();
    var machine = try @import("../Machine.zig").init(std.testing.allocator, &invalid, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqualStrings("expected picture, received int", machine.failure.?.text());
}

test "lowered loops and short circuit contain bounded explicit jumps" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\n:=0
        \\for i in 1:2:7 do
        \\  if i==3 then; continue; end
        \\  n=n+i
        \\  if n>8 then; break; end
        \\end
        \\while n<20 do
        \\  n=n+1
        \\end
        \\a := false and (1/0 > 0)
        \\b := true or (1/0 > 0)
    , "loops.huak", .{}, &diagnostic);
    defer program.deinit();
    var range_tests: usize = 0;
    var range_advances: usize = 0;
    for (program.functions[0].code) |instruction| switch (instruction.op) {
        .jump, .jump_if_false => try std.testing.expect(instruction.a < program.functions[0].code.len),
        .iterate_test => range_tests += 1,
        .iterate_advance => range_advances += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), range_tests);
    try std.testing.expectEqual(@as(usize, 1), range_advances);
}

test "declarations cannot hide in conditional scopes and annotations remain stable" {
    const cases = [_][]const u8{
        "if true then; param n:int=1; end\n",
        "if true then; fn f(); end; end\n",
        "x:int:=1\nx=1.5\n",
        "for i in 1:0.5:2 do; end\ni=true\n",
        "fn f(x:int)->int;return x;end\ny:=f(false)\n",
        "p:=(1,2)\nx:=p.width\n",
    };
    for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "types.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}
