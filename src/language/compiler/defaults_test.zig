//! Tests of parameter and function defaults.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const ModuleGraph = @import("../ModuleGraph.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const compile = compilation.compile;

test "parameter defaults infer supported types without changing explicit annotations" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\param path="."
        \\param count=-3
        \\param size=2.5
        \\param enabled=not false
        \\param angle=3.141592653589793
        \\param wide:float=1
        \\param required:int
        \\export count
    , "inferred-param.huak", .{}, &diagnostic);
    defer program.deinit();
    const expected = [_]Type{ .string, .int, .number, .boolean, .number, .number, .int };
    try std.testing.expectEqual(expected.len, program.parameters.len);
    for (expected, program.parameters) |kind, parameter| {
        try std.testing.expectEqual(kind, parameter.kind);
        try std.testing.expect(program.readonly_globals[parameter.global]);
    }
    try std.testing.expect(program.parameters[6].default == null);
    const invalid = [_][]const u8{ "param x=1/0", "param x=sin(1)", "param x=[1]", "param x=(1,2)", "param x=missing", "param x:any=1", "param x=\"str\";x=\"other\"" };
    for (invalid) |input| {
        diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "bad-param.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

test "function defaults retain ordinary dot and both mixfix call forms" {
    const input =
        \\fn combine(a:int,b:int=2)->int return a*10+b end
        \\mixfix(combine) combine _ with _ in unary
        \\mixfix(combine) _ combine _ in addition
        \\plain:=combine(3)
        \\value:=3
        \\dot:=value.combine()
        \\prefixed:=combine 3
        \\word:=value combine 4
        \\mixed:=combine 3 with 2
        \\events:=[]
        \\fn record(x:int)->int events+=x;return x end
        \\explicit:=combine(record(1),record(2))
        \\fn settings(value:float=1,position:vec2=(0mm,1mm),label:string="默认")->list
        \\    return [value,position,label]
        \\end
        \\configured:=settings()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "function-defaults.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.functions[1].requiredCount());
        try std.testing.expectEqual(@as(usize, 2), program.functions[1].fixedCount());
        try std.testing.expect(program.functions[1].acceptsCount(1));
        try std.testing.expect(!program.functions[1].acceptsCount(0));
        for (0..2) |_| {
            var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            for ([_][]const u8{ "plain", "dot", "prefixed", "mixed" }) |name|
                try std.testing.expectEqual(@as(i64, 32), machine.getGlobal(name).?.int);
            try std.testing.expectEqual(@as(i64, 34), machine.getGlobal("word").?.int);
            try std.testing.expectEqual(@as(i64, 12), machine.getGlobal("explicit").?.int);
            const events = @import("../types.zig").sequence(machine.getGlobal("events").?).?;
            try std.testing.expectEqual(@as(usize, 2), events.len);
            try std.testing.expectEqual(@as(i64, 1), events[0].int);
            try std.testing.expectEqual(@as(i64, 2), events[1].int);
            const configured = @import("../types.zig").sequence(machine.getGlobal("configured").?).?;
            try std.testing.expectEqual(@as(f64, 1), configured[0].number);
            try std.testing.expectEqualStrings("默认", configured[2].string);
        }
    }
}

test "function default list templates are fresh while explicit lists remain shared" {
    const input =
        \\fn fresh(values:list=[[1]])->list
        \\    child:=values[0];child+=2;values+=3
        \\    return values
        \\end
        \\first:=fresh()
        \\second:=fresh()
        \\child:=first[0];child+=4
        \\seed:=[[7]]
        \\explicit:=fresh(seed)
        \\fn gather(head:int=7,rest:int...)->list return [head,rest] end
        \\empty:=gather()
        \\fixed:=gather(8)
        \\full:=gather(8,9,10)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "function-default-lists.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            const sequence = @import("../types.zig").sequence;
            const first = sequence(machine.getGlobal("first").?).?;
            const second = sequence(machine.getGlobal("second").?).?;
            try std.testing.expectEqual(@as(usize, 3), sequence(first[0]).?.len);
            try std.testing.expectEqual(@as(usize, 2), sequence(second[0]).?.len);
            const seed = sequence(machine.getGlobal("seed").?).?;
            try std.testing.expectEqual(@as(usize, 2), seed.len);
            try std.testing.expectEqual(@as(i64, 2), sequence(seed[0]).?[1].int);
            const empty = sequence(machine.getGlobal("empty").?).?;
            try std.testing.expectEqual(@as(i64, 7), empty[0].int);
            try std.testing.expectEqual(@as(usize, 0), sequence(empty[1]).?.len);
            const full = sequence(machine.getGlobal("full").?).?;
            try std.testing.expectEqual(@as(i64, 8), full[0].int);
            try std.testing.expectEqual(@as(usize, 2), sequence(full[1]).?.len);
            const template = sequence(program.functions[1].defaults[0].?).?;
            try std.testing.expectEqual(@as(usize, 1), template.len);
            try std.testing.expectEqual(@as(usize, 1), sequence(template[0]).?.len);
        }
    }
}

test "function defaults stay attached to aliases namespaces and reexports" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "library")) return .{ .name = "library.huak", .source =
            \\export fn add(a:int,b:int=4)->int return a+b end
            \\mixfix(add) add to _ in unary
            };
            return .{ .name = "bridge.huak", .source = "import \"library\".add as sum;export sum" };
        }
    };
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\import "bridge" as tools
            \\import "library".add as total
            \\a:=tools.sum(3)
            \\b:=tools.add to 4
            \\c:=total(5)
            \\export total
        , "default-aliases.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        const target = program.exports[0].target.function;
        try std.testing.expectEqual(@as(i64, 4), program.functions[target].defaults[1].?.int);
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("a").?.int);
        try std.testing.expectEqual(@as(i64, 8), machine.getGlobal("b").?.int);
        try std.testing.expectEqual(@as(i64, 9), machine.getGlobal("c").?.int);
    }
}

test "function defaults validate unused declarations and retain strict arity and types" {
    const invalid = [_][]const u8{
        "fn f(a:int=1,b:int) end",
        "fn f(a:int=1,rest:int...=2) end",
        "fn f(a=1) end",
        "fn f(a:int=\"bad\") end",
        "fn f(a:int=1/0) end",
        "fn f(a:int=9223372036854775807+1) end",
        "fn f(a:int,b:int=1) end; f()",
        "fn f(a:int,b:int=1) end; f(1,2,3)",
        "fn f(a:int,b:int=1) end; f(1,\"bad\")",
        "fn f(a:list=[missing]) end",
    };
    for ([_]bool{ false, true }) |optimize| for (invalid) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid-function-default.huak", .{ .optimize = optimize }, &diagnostic));
        try std.testing.expect(diagnostic != null);
    };
}

test "function defaults cannot implicitly capture parameters" {
    const cases = [_][]const u8{
        "fn f(pi:float,x:float=pi) end",
        "fn f(x:float=pi,pi:float=1) end",
        "fn f(pi:float=pi) end",
        "fn f(cm:float,x:length=cm) end",
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "shadowed-function-default.huak", .{ .optimize = optimize }, &diagnostic));
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "function default cannot reference") != null);
    };
}

test "function defaults resolve ordinary imported bindings" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "values.huak", .source = "export pi:=1; export tau:=2; export e:=3; export cm:=4" };
        }
    };
    const cases = [_][]const u8{
        "import \"values\".pi; fn f(x:float=pi) end",
        "import \"values\".{tau,e}; fn f(x:vec2=(tau,e)) end",
        "import \"values\".pi as cm; fn f(x:list=[[cm]]) end",
        "import \"values\".*; fn f(x:angle=pi rad) end",
    };
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "imported-function-default.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        for (program.functions, 0..) |function, index| if (std.mem.eql(u8, function.name, "f")) {
            _ = try machine.invokeFunction(.{ .function = .{ .bytecode = @intCast(index) } }, &.{});
        };
    };
}

test "function defaults keep literal constants and explicit units without changing CLI defaults" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\fn constants(angle:angle=(2*3.141592653589793) rad,point:vec2=(6.283185307179586,2.718281828459045),items:list=[[mm]])->list
            \\    return [angle,point,items]
            \\end
            \\result:=constants()
            \\cm:=7
            \\fn explicit(cm:float=2,distance:length=1cm)->length return distance end
            \\distance:=explicit()
        , "literal-function-default.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const result = @import("../types.zig").sequence(machine.getGlobal("result").?).?;
        try std.testing.expectEqual(@as(f64, 2 * std.math.pi), result[0].quantity.value);
        try std.testing.expectEqual(@as(f64, 2 * std.math.pi), result[1].vec2.x);
        try std.testing.expectEqual(@as(f64, std.math.e), result[1].vec2.y);
        try std.testing.expectEqual(@as(f64, 10), machine.getGlobal("distance").?.quantity.value);

        var cli = try compile(std.testing.allocator, "pi:=1; param angle:float=3.141592653589793", "unchanged-cli-default.huak", .{ .optimize = optimize }, &diagnostic);
        defer cli.deinit();
        try std.testing.expectEqual(@as(f64, std.math.pi), cli.parameters[0].default.?.number);
    }
}

fn functionDefaultAllocationExercise(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(allocator,
            \\export fn f(items:list=[[1,2]],label:string="retained Ω",count:int=2*3)->list
            \\    return [items,label,count]
            \\end
            \\value:=f()
        , "default-allocation.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 0), program.functions[1].requiredCount());
    }
}

test "function default metadata releases all partial allocations" {
    try functionDefaultAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), functionDefaultAllocationExercise, .{});
}

test "nested native constants work in defaults without bypassing parameter shadowing" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\import std
        \\fn pi(value:float = std.math.PI) -> float
        \\    return value
        \\end
        \\result := pi()
    , "nested-default.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(std.math.pi, machine.getGlobal("result").?.number);
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator,
        \\import std
        \\fn bad(std:int, value:float = std.math.PI) -> float
        \\    return value
        \\end
    , "shadowed-namespace-default.huak", .{}, &diagnostic));
    try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "cannot reference parameter 'std'") != null);
}
