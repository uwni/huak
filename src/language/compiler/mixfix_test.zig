//! Tests of mixfix templates: bytecode, imports, initialization, validation and allocation failure.
const std = @import("std");
const source = @import("../source.zig");
const builtin = @import("../builtin.zig");
const ModuleGraph = @import("../ModuleGraph.zig");
const precedence = @import("../precedence.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const CompileOptions = compilation.CompileOptions;
const compile = compilation.compile;

test "reexported native templates retain their own group in nested blocks" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "brush.huak", .source =
            \\import object.draw as paint
            \\precedence stroke_scope above addition;end
            \\mixfix(paint) paint _ in stroke_scope
            \\export paint
            };
        }
    };
    var context: u8 = 0;
    for ([_][]const u8{ "paint", "brush.paint" }) |head| {
        for ([_]bool{ false, true }) |grouped| {
            const input = try std.fmt.allocPrint(
                std.testing.allocator,
                "import \"brush\".paint;import \"brush\" as brush\nimport geometry.joined as join\nmixfix(join) _ join _ in addition\np:=path((0,0),(1,1));q:=path((1,1),(2,2))\nblock\n{s} {s}\nend",
                .{ head, if (grouped) "(p join q)" else "p join q" },
            );
            defer std.testing.allocator.free(input);
            var diagnostic: ?Diagnostic = null;
            const options: CompileOptions = .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } };
            if (grouped) {
                var program = try compile(std.testing.allocator, input, "native-group.huak", options, &diagnostic);
                defer program.deinit();
            } else {
                try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "native-group.huak", options, &diagnostic));
                try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "path") != null);
            }
        }
    }
}

test "mixfix uses ordinary bytecode and evaluates argument slots once in order" {
    const declarations =
        \\mixfix(combine) combine from _ with _ in unary
        \\export fn combine(a:int,b:int)->int return a*100+b*10 end
        \\calls:=[]
        \\fn record(value:int)->int calls+=value; return value end
        \\
    ;
    const mixed_source = try std.fmt.allocPrint(std.testing.allocator, "{s}answer:=combine from record(1) with record(2)+3", .{declarations});
    defer std.testing.allocator.free(mixed_source);
    const ordinary_source = try std.fmt.allocPrint(std.testing.allocator, "{s}answer:=combine(record(1),record(2))+3", .{declarations});
    defer std.testing.allocator.free(ordinary_source);
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var mixed = try compile(std.testing.allocator, mixed_source, "mixed.huak", .{ .optimize = optimize }, &diagnostic);
        defer mixed.deinit();
        var ordinary = try compile(std.testing.allocator, ordinary_source, "ordinary.huak", .{ .optimize = optimize }, &diagnostic);
        defer ordinary.deinit();
        for (ordinary.functions, mixed.functions) |expected, actual| {
            try std.testing.expectEqual(expected.code.len, actual.code.len);
            for (expected.code, actual.code) |a, b| {
                try std.testing.expectEqual(a.op, b.op);
                try std.testing.expectEqual(a.a, b.a);
                try std.testing.expectEqual(a.b, b.b);
            }
        }
        const form = mixed.exports[0].mixfix[0].?;
        try std.testing.expectEqual(precedence.builtinId(.unary), form.group);
        try std.testing.expectEqualStrings("from", form.parts[0].?);
        try std.testing.expect(form.parts[1] == null);
        try std.testing.expectEqualStrings("with", form.parts[2].?);
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &mixed, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 123), machine.getGlobal("answer").?.int);
        const calls = @import("../types.zig").sequence(machine.getGlobal("calls").?).?;
        try std.testing.expectEqual(@as(usize, 2), calls.len);
        try std.testing.expectEqual(@as(i64, 1), calls[0].int);
        try std.testing.expectEqual(@as(i64, 2), calls[1].int);
    }
}

const MixfixModules = struct {
    pub fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
        if (std.mem.eql(u8, path, "forms")) return .{ .name = "forms.huak", .source =
        \\precedence phrase above logical_or; below addition end
        \\mixfix(combine) combine from _ with _ in phrase
        \\export fn combine(a:int,b:int)->int return a*100+b*10 end
        \\mixfix(len) len of _ in unary
        \\export len
        };
        if (std.mem.eql(u8, path, "bridge")) return .{ .name = "bridge.huak", .source =
        \\import "forms".{combine as build,len as count}
        \\export build,count
        };
        return error.UnknownModule;
    }
};

test "mixfix imports preserve alias scope native identity and private precedence origin" {
    var context: u8 = 0;
    const input =
        \\precedence phrase above multiplication end
        \\import "bridge" as library
        \\import "forms".combine as make
        \\a:=library.combine from 1 with 2+3
        \\b:=combine from 1 with 2+3
        \\n:=library.len of [7,8,9]
        \\inner:=0
        \\if true then
        \\    mixfix(make) make first _ second _ in unary
        \\    inner=make first 1 second 2+3
        \\end
        \\outer:=combine from 1 with 2+3
        \\ordinary:=library.count([1,2])
        \\export make
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = MixfixModules.resolve } }, .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 3), program.modules.len);
        try std.testing.expect(program.exports[0].mixfix[0].?.group != precedence.builtinId(.unary));
        var native_calls: usize = 0;
        for (program.functions[program.entry].code) |instruction| if (instruction.op == .call_builtin) {
            try std.testing.expectEqual(@backingInt(builtin.Id.len), instruction.a);
            native_calls += 1;
        };
        try std.testing.expectEqual(@as(usize, 2), native_calls);
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        for ([_][]const u8{ "a", "b", "outer" }) |name| try std.testing.expectEqual(@as(i64, 150), machine.getGlobal(name).?.int);
        try std.testing.expectEqual(@as(i64, 123), machine.getGlobal("inner").?.int);
        try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("n").?.int);
        try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("ordinary").?.int);
    }
}

test "mixfix imported native calls check module initialization before argument effects" {
    var context: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\calls:=[]
        \\fn source()->list calls+=1; return [7] end
        \\answer:=early()
        \\import "bridge".count
        \\fn early()->int; return len of source(); end
    , "early.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = MixfixModules.resolve } } }, &diagnostic);
    defer program.deinit();
    var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "not initialized") != null);
    try std.testing.expectEqual(@as(usize, 0), @import("../types.zig").sequence(machine.getGlobal("calls").?).?.len);
}

test "mixfix declarations validate callable arity groups and unused branches" {
    const cases = [_][]const u8{
        "mixfix(missing) missing from _ with _ in unary",
        "mixfix(len) len from _ with _ in unary",
        "fn f(a:int,b:int)->int return a+b end; mixfix(f) f from _ in unary",
        "fn f(a:int,b:int)->int return a+b end; mixfix(f) f from _ with _ in missing",
        "if false then mixfix(missing) missing from _ with _ in unary end",
        "fn f(a:int,b:int)->int return a+b end; mixfix(f) f from _ with _ in unary; value:=f from 1 with true",
    };
    for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid-mixfix.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

fn mixfixAllocationExercise(allocator: std.mem.Allocator) !void {
    var context: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator, "import \"bridge\".{build,count}; result:=combine from 1 with (len of [1,2])", "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = MixfixModules.resolve } } }, &diagnostic);
    defer program.deinit();
}

test "mixfix template imports and persistent metadata release every allocation failure" {
    try mixfixAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), mixfixAllocationExercise, .{});
}
