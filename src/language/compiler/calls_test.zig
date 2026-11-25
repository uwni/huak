//! Tests of partial application, record calls, variadic functions, recursion and dot calls.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const ModuleGraph = @import("../ModuleGraph.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const testing = @import("testing.zig");
const compile = compilation.compile;
const testGlobalType = testing.testGlobalType;

test "explicit partial application retains values and ordinary mixfix calls" {
    const input =
        \\fn add(a:int, b:int, c:int=4) -> int; return a+b+c; end
        \\fn bind(a:int) -> function; return add.with(a: a); end
        \\f := bind(2)
        \\first := f(b:3)
        \\g := add.with(1).with(c:8)
        \\second := g(2)
        \\third := g(b:2,c:10)
        \\fourth := block
        \\    add := add.with(1,c:3)
        \\    mixfix(add) add _ in unary
        \\    return add 2
        \\end
        \\size := len.with("abc")
        \\fifth := size()
        \\fn collect(a:int, rest:int...) -> list; return rest; end
        \\tail := collect.with(1,2)
        \\values := tail(3,4)
        \\events := []
        \\fn mark(value:int) -> int; events+=value; return value; end
        \\fn deferred(a:int, b:int=block
        \\    local:=mark(8)
        \\    return local+1
        \\end) -> int; return a+b; end
        \\ready := deferred.with(a:mark(1))
        \\before := len(events)
        \\sixth := ready()
        \\seventh := ready(b:mark(2))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = compile(std.testing.allocator, input, "partial-values.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
            return err;
        };
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = machine.execute(&.{}) catch |err| {
            if (machine.failure) |failure| std.debug.print("{s}\n", .{failure.diagnostic.text()});
            return err;
        };
        inline for (.{ "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "before" }, .{ 9, 11, 13, 6, 3, 10, 3, 1 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        const events = machine.getGlobal("events").?.list.items();
        try std.testing.expectEqual(@as(usize, 3), events.len);
        for (events, [_]i64{ 1, 8, 2 }) |event, expected| try std.testing.expectEqual(expected, event.int);
        for (machine.getGlobal("values").?.list.items(), 2..) |value, expected|
            try std.testing.expectEqual(@as(i64, @intCast(expected)), value.int);
    }
}

test "ordinary and dot record calls retain their signatures" {
    const input =
        \\struct Empty;end
        \\struct Broken;end
        \\fn ordinary(value:Broken)->int return 4 end
        \\fn plain(value:Empty)->int return 3 end
        \\mixfix(ordinary) ordinary _ in unary
        \\mixfix(plain) plain _ in unary
        \\mixed:=ordinary Broken()
        \\mixed_plain:=plain Empty()
        \\first:=ordinary(Broken())
        \\second:=Broken().ordinary()
        \\third:=plain(Empty())
        \\fourth:=Empty().plain()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "ordinary-record-hooks.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        for ([_][]const u8{ "first", "second", "mixed" }) |name| try std.testing.expectEqual(@as(i64, 4), machine.getGlobal(name).?.int);
        for ([_][]const u8{ "third", "fourth", "mixed_plain" }) |name| try std.testing.expectEqual(@as(i64, 3), machine.getGlobal(name).?.int);
    }
}

test "variadic functions own their argument list and retain shallow element references" {
    const input =
        \\shared:=[1]
        \\empty:=gather()
        \\mixed:=gather(shared,2)
        \\shared+=8
        \\coerced:=numbers(1,2.5)
        \\prefixed:=3.with_tail(4,5)
        \\fn gather(values...)->list
        \\    values+=9
        \\    return values
        \\end
        \\fn numbers(values:float...)->list return values end
        \\fn with_tail(head:int,tail:int...)->list return [head,tail] end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "variadic.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        const gather = program.functions[1];
        try std.testing.expectEqual(Type.any, gather.variadic.?);
        try std.testing.expectEqual(@as(usize, 0), gather.fixedCount());
        try std.testing.expectEqual(Type.list, gather.parameters[0]);
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const sequence = @import("../types.zig").sequence;
        try std.testing.expectEqual(@as(usize, 1), sequence(machine.getGlobal("empty").?).?.len);
        const mixed = sequence(machine.getGlobal("mixed").?).?;
        try std.testing.expectEqual(@as(usize, 3), mixed.len);
        try std.testing.expectEqual(@as(usize, 2), sequence(mixed[0]).?.len);
        try std.testing.expectEqual(@as(usize, 2), sequence(machine.getGlobal("shared").?).?.len);
        const coerced = sequence(machine.getGlobal("coerced").?).?;
        try std.testing.expectEqual(@as(f64, 1), coerced[0].number);
        try std.testing.expectEqual(@as(f64, 2.5), coerced[1].number);
        const prefixed = sequence(machine.getGlobal("prefixed").?).?;
        try std.testing.expectEqual(@as(i64, 3), prefixed[0].int);
        const tail = sequence(prefixed[1]).?;
        try std.testing.expectEqual(@as(i64, 4), tail[0].int);
        try std.testing.expectEqual(@as(i64, 5), tail[1].int);
    }
}

test "variadic aliases preserve ordinary dot prefix and infix call roles" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "library.huak", .source =
            \\export fn count(values:int...)->int return len(values) end
            \\mixfix(count) count _ in unary
            \\export fn plus(head:int,tail:int...)->int return head+tail[0] end
            \\mixfix(plus) _ plus _ in addition
            };
        }
    };
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\import "library.huak".{count as size,plus as combine}
            \\a:=size(1,2,3)
            \\b:=count 9
            \\c:=4.combine(6,7)
            \\d:=4 plus 6
        , "root.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("a").?.int);
        try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("b").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("c").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("d").?.int);
    }
}

test "variadic calls check fixed prefixes and declared element types" {
    const invalid = [_][]const u8{
        "fn f(head:int,tail:vec2...);end;f()",
        "fn f(head:int,tail:vec2...);end;f(1,2)",
        "fn f(values:missing...);end",
        "fn f(a:int,b:int,c:int,rest...);end;mixfix(f) _ f _ in addition",
        "fn f(a:int,b:int,c:int,rest...);end;mixfix(f) f _ in unary",
    };
    for (invalid) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid-variadic.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

test "compiler resolves recursive and forward functions to linear code" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "param n:int=6\nanswer:=fact(n)\nfn fact(x:int)->int\nif x<=1 then; return 1; end\nreturn x*fact(x-1)\nend\n", "test.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 2), program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), program.parameters.len);
    try std.testing.expect(program.readonly_globals[program.parameters[0].global]);
    var calls: usize = 0;
    for (program.functions) |function| for (function.code) |instruction| if (instruction.op == .call) {
        calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "dot calls compile exactly like free builtin forward and recursive calls" {
    var diagnostic: ?Diagnostic = null;
    var dotted = try compile(std.testing.allocator,
        \\import math.{pow, sqrt}
        \\values:=[2,3]
        \\a:=(1+2).pow(3).sqrt()
        \\b:=values[0].combine(4)
        \\c:=4.factorial()
        \\fn combine(x:int,y:int)->int; return x*10+y; end
        \\fn factorial(x:int)->int
        \\  if x<=1 then; return 1; end
        \\  return x*(x-1).factorial()
        \\end
    , "dot.huak", .{}, &diagnostic);
    defer dotted.deinit();
    var free = try compile(std.testing.allocator,
        \\import math.{pow, sqrt}
        \\values:=[2,3]
        \\a:=sqrt(pow(1+2,3))
        \\b:=combine(values[0],4)
        \\c:=factorial(4)
        \\fn combine(x:int,y:int)->int; return x*10+y; end
        \\fn factorial(x:int)->int
        \\  if x<=1 then; return 1; end
        \\  return x*factorial(x-1)
        \\end
    , "free.huak", .{}, &diagnostic);
    defer free.deinit();
    try std.testing.expectEqualSlices(Type, free.global_types, dotted.global_types);
    try std.testing.expectEqual(free.constants.len, dotted.constants.len);
    for (free.constants, dotted.constants) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(free.functions.len, dotted.functions.len);
    for (free.functions, dotted.functions) |expected, actual| {
        try std.testing.expectEqual(expected.code.len, actual.code.len);
        for (expected.code, actual.code) |free_instruction, dot_instruction| {
            try std.testing.expectEqual(free_instruction.op, dot_instruction.op);
            try std.testing.expectEqual(free_instruction.a, dot_instruction.a);
            try std.testing.expectEqual(free_instruction.b, dot_instruction.b);
        }
    }
}

test "dot calls share unknown function arity and type diagnostics with free calls" {
    const cases = [_]struct { dotted: []const u8, free: []const u8 }{
        .{ .dotted = "p:=(1,2); p.missing()", .free = "p:=(1,2); missing(p)" },
        .{ .dotted = "p:=(1,2); p.x()", .free = "p:=(1,2); x(p)" },
        .{ .dotted = "import math.sin; 2.sin(3)", .free = "import math.sin; sin(2,3)" },
        .{ .dotted = "import math.min; 2.min()", .free = "import math.min; min(2)" },
        .{ .dotted = "import math.sin; \"bad\".sin()", .free = "import math.sin; sin(\"bad\")" },
        .{ .dotted = "import text.width; 1.width()", .free = "import text.width; width(1)" },
        .{ .dotted = "1.f()\nfn f(x:int,y:int);end", .free = "f(1)\nfn f(x:int,y:int);end" },
        .{ .dotted = "false.f()\nfn f(x:int);end", .free = "f(false)\nfn f(x:int);end" },
    };
    for (cases) |case| {
        var dotted: ?Diagnostic = null;
        var free: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.dotted, "dot.huak", .{}, &dotted));
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.free, "free.huak", .{}, &free));
        try std.testing.expectEqualStrings(free.?.text(), dotted.?.text());
    }
}

test "properties stay distinct from dot calls with explicitly aliased functions" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\import text.{width, height, baseline}; import math.sin as sine; import solver.{solver, solve}
        \\sin:=99
        \\a:=1.sine()
        \\fn metrics(t:text)->length
        \\  return t.width+t.width()+t.height+t.height()+t.baseline+t.baseline()
        \\end
        \\fn status(s:solution)->string; return s.status; end
        \\s:=solver().solve()
        \\tag:=s.status()
        \\point:=(2,3)
        \\coordinate:=point.x
        \\custom:=point.x()
        \\fn x(p:vec2)->float; return p.y; end
    , "members.huak", .{}, &diagnostic);
    defer program.deinit();
    const expected = [_]Type{ .int, .number, .solution, .string, .vec2, .scalar, .number };
    for (expected, [_][]const u8{ "sin", "a", "s", "tag", "point", "coordinate", "custom" }) |kind, name| try std.testing.expectEqual(kind, testGlobalType(&program, name));
}
