//! Tests of infix and prefix calls and symbolic mixfix.
const std = @import("std");
const source = @import("../source.zig");
const precedence = @import("../precedence.zig");
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const compile = compilation.compile;

test "infix and ordinary calls produce the same checked and optimized instructions" {
    const declarations =
        \\precedence combine_group
        \\ above addition
        \\ associativity left
        \\end
        \\mixfix(combine) _ combine _ in combine_group
        \\fn combine(a:int,b:int)->int;return a*10+b;end
        \\
    ;
    const left = try std.testing.allocator.print("{s}answer:=1 combine 2 combine 3\n", .{declarations});
    defer std.testing.allocator.free(left);
    const right = try std.testing.allocator.print("{s}answer:=combine(combine(1,2),3)\n", .{declarations});
    defer std.testing.allocator.free(right);
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var infix = try compile(std.testing.allocator, left, "infix.huak", .{ .optimize = optimize }, &diagnostic);
        defer infix.deinit();
        var ordinary = try compile(std.testing.allocator, right, "ordinary.huak", .{ .optimize = optimize }, &diagnostic);
        defer ordinary.deinit();
        try std.testing.expectEqual(ordinary.constants.len, infix.constants.len);
        for (ordinary.constants, infix.constants) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqual(ordinary.functions.len, infix.functions.len);
        for (ordinary.functions, infix.functions) |expected, actual| {
            try std.testing.expectEqual(expected.code.len, actual.code.len);
            for (expected.code, actual.code) |a, b| {
                try std.testing.expectEqual(a.op, b.op);
                try std.testing.expectEqual(a.a, b.a);
                try std.testing.expectEqual(a.b, b.b);
            }
        }
    }
}

fn prefixDrawingAllocationExercise(allocator: std.mem.Allocator) !void {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\expand_block drawing(target:picture)
        \\    ...
        \\    return target
        \\end
        \\import object.{fill, draw}; import geometry.reverse
        \\mixfix(draw) draw _ in logical_or
        \\export paint
        \\mixfix(paint) paint _ in logical_or
        \\fn paint(p:path)->object;return fill(p);end
        \\mixfix(reverse) reverse _ in unary
        \\export pic:=picture(640, 480)
        \\curve:=path((0,0),(10,10))
        \\drawing pic do
        \\ draw reverse curve
        \\ drawing pic do;paint curve;end
        \\end
    , "allocation-prefix.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(precedence.builtinId(.logical_or), program.exports[0].mixfix[0].?.group);
    try std.testing.expectEqual(@as(usize, 4), program.functions[program.entry].local_types.len);
}

test "prefix declarations and drawing targets release every failed compilation allocation" {
    try prefixDrawingAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), prefixDrawingAllocationExercise, .{});
}

fn infixAllocationExercise(allocator: std.mem.Allocator) !void {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\precedence transform
        \\ below addition
        \\ above path
        \\ associativity left
        \\end
        \\mixfix(combine) _ combine _ in transform
        \\export transform
        \\export combine
        \\fn combine(a:int,b:int)->int;return a*10+b;end
        \\result:=1 combine 2+1 combine 4
    , "allocation-infix.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 2), program.exports.len);
    var machine = try @import("../Machine.zig").init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 134), machine.getGlobal("result").?.int);
}

test "infix compilation metadata and execution release every failed allocation" {
    try infixAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), infixAllocationExercise, .{});
}

test "symbolic mixfix is lexical and nested expansion forwards its insertion" {
    const input =
        \\fn twice(x:int)->int return x*2 end
        \\fn difference(a:int,b:int)->int return a-b end
        \\a := block
        \\    mixfix(twice) + _ in unary
        \\    return +3 + 4
        \\end
        \\b := block
        \\    mixfix(difference) _ + _ in addition
        \\    return 20 + 2*3
        \\end
        \\c := +3 + 4
        \\events := []
        \\expand_block foo(target:list)
        \\    target += 1
        \\    ...
        \\    target += 5
        \\end
        \\expand_block bar(target:list)
        \\    target += 0
        \\    foo target do
        \\        local := 3
        \\        target += 2
        \\        ...
        \\        target += 4
        \\    end
        \\    target += 6
        \\end
        \\bar events do events += local end
        \\expand_block nested(target:list)
        \\    if true then
        \\        local := 7
        \\        ...
        \\    end
        \\end
        \\nested events do events += local end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = compile(std.testing.allocator, input, "symbol-nested.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
            return err;
        };
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        inline for (.{ "a", "b", "c" }, .{ 10, 14, 7 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        const events = machine.getGlobal("events").?.list.items();
        try std.testing.expectEqual(@as(usize, 8), events.len);
        for (events, 0..) |value, index| try std.testing.expectEqual(@as(i64, @intCast(index)), value.int);
    }
}
