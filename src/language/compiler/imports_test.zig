//! Tests of imports: selected bindings, operator groups, native calls, initialization order and nested namespaces.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Type = bc.Type;
const ModuleGraph = @import("../ModuleGraph.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const ImportResolver = ModuleGraph.ImportResolver;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const testing = @import("testing.zig");
const compile = compilation.compile;
const testGlobalType = testing.testGlobalType;
const ModuleTestSources = testing.ModuleTestSources;

test "selected data imports shadow calls while explicit function aliases remain available" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "data.huak", .source = "export sin:=7" };
        }
    };
    var context: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    const resolver: ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    var program = try compile(std.testing.allocator, "import math.sin as sine; import \"data.huak\".sin; value:=sin; angle:=sine(0)", "root.huak", .{ .import_resolver = resolver }, &diagnostic);
    defer program.deinit();
    var builtin_calls: usize = 0;
    for (program.functions[program.entry].code) |instruction| if (instruction.op == .call_builtin) {
        try std.testing.expectEqual(@backingInt(builtin.lookup("sin").?.id), instruction.a);
        builtin_calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), builtin_calls);
    try std.testing.expectEqual(Type.int, testGlobalType(&program, "value"));
    try std.testing.expectEqual(Type.number, testGlobalType(&program, "angle"));
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "import math.sin; import \"data.huak\".sin; value:=sin(0)", "shadowed.huak", .{ .import_resolver = resolver }, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "not callable") != null);
}

test "reexported operator groups must agree when the same function is imported twice" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "base")) return .{ .name = "base.huak", .source = "export fn f(a:int,b:int)->int return a+b end;mixfix(f) _ f _ in addition" };
            return .{ .name = "bridge.huak", .source = "import \"base\".f;mixfix(f) _ f _ in multiplication;export f" };
        }
    };
    var context: u8 = 0;
    for ([_][]const u8{ "import \"base\".f;import \"bridge\".f", "import \"bridge\".f;import \"base\".f" }) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "conflicting imported operator roles") != null);
    }
}

test "qualified native calls preserve data names and native member result types" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\param scale:float=1.5
        \\matrix:=transform.scale(scale)
        \\s:=solver(); result:=solver.solve(s)
        \\status:string:=result.status
        \\rank:int:=result.rank
    , "names.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(Type.number, testGlobalType(&program, "scale"));
    try std.testing.expectEqual(Type.transform, testGlobalType(&program, "matrix"));
    try std.testing.expectEqual(Type.string, testGlobalType(&program, "status"));
    try std.testing.expectEqual(Type.int, testGlobalType(&program, "rank"));
}

fn moduleAllocationExercise(allocator: std.mem.Allocator) !void {
    var marker: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\import "left.huak" as left
        \\import "right.huak" as right
        \\export result:=left.get()+right.get()
    , "root.huak", .{ .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = ModuleTestSources.resolve } } }, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 4), program.modules.len);
    var calls: usize = 0;
    for (0..2) |_| {
        var machine = try @import("../Machine.zig").init(allocator, &program, .{ .ptr = &calls, .vtable = &.{ .callBuiltin = ModuleTestSources.count } }, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("result").?.int);
        try std.testing.expect(machine.getGlobal("count") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "diamond imports initialize once per execution and release every allocation failure" {
    try moduleAllocationExercise(std.testing.allocator);
    // Arena growth can resize in place depending on the backing heap layout.
    // Disable backing resizes so every allocation-failure run has the same work.
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), moduleAllocationExercise, .{});
}

test "standard assertions execute without a host and retain optional failure messages" {
    const cases = [_]struct { arguments: []const u8, message: ?[]const u8 }{
        .{ .arguments = "true", .message = null },
        .{ .arguments = "true,\"unused Ω\"", .message = null },
        .{ .arguments = "false", .message = "assertion failed" },
        .{ .arguments = "false,\"验证失败 Ω\"", .message = "验证失败 Ω" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "import \"std/assertions.huak\".assert\nexport assert\nassert({s})\ncompleted:=1\n",
            .{case.arguments},
        );
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "pure-assertions.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 2), program.modules.len);
        try std.testing.expectEqualStrings("std/assertions.huak", program.modules[1].name);
        try std.testing.expect(program.exports[0].target == .function);
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        if (case.message) |message| {
            try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try std.testing.expectEqualStrings(message, machine.failure.?.native_message);
            try std.testing.expectEqualStrings("assert", machine.failure.?.trace[0].function);
            try std.testing.expect(machine.getGlobal("completed") == null);
        } else {
            _ = try machine.execute(&.{});
            try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("completed").?.int);
        }
    };
}

test "nested namespace imports preserve parent initialization and nominal type identity" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "facade")) return .{ .name = "facade.huak", .source =
            \\import "tools" as tools
            \\tools.values[0] = tools.values[0] + 1
            \\export tools
            };
            if (std.mem.eql(u8, path, "tools")) return .{ .name = "tools.huak", .source =
            \\export values := [0]
            \\export struct Item
            \\    value:int = 7
            \\end
            };
            return error.MissingModule;
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var opaque_context: u8 = 0;
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\import "facade".tools.values
            \\import "facade" as library
            \\import "tools".Item as LocalItem
            \\fn read(item:library.tools.Item) -> int
            \\    return item.value
            \\end
            \\count := values[0]
            \\item := library.tools.Item()
            \\other:LocalItem := item
            \\result := read(other)
            \\export library
        , "namespaces.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &opaque_context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        try std.testing.expect(program.exports[0].target == .namespace);
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("count").?.int);
        try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("result").?.int);
    }
}

test "nested namespace access checks the facade before argument effects even when the leaf is ready" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "tools")) return .{ .name = "tools.huak", .source =
            \\export values := [0]
            \\export fn f(value:int) -> int
            \\    return value
            \\end
            };
            if (std.mem.eql(u8, path, "facade")) return .{ .name = "facade.huak", .source =
            \\import "tools" as tools
            \\tools.values[0] = 1
            \\export tools
            };
            return error.MissingModule;
        }
    };
    for ([_]struct { imported: []const u8, expression: []const u8 }{
        .{ .imported = "import \"facade\" as library", .expression = "library.tools.f(effect())" },
        .{ .imported = "import \"facade\".tools.f", .expression = "f(effect())" },
        .{ .imported = "import \"facade\".tools.values", .expression = "values[0]" },
        .{ .imported = "import \"facade\".tools as library", .expression = "library.f(effect())" },
        .{ .imported = "import \"facade\" as library", .expression = "library.tools.values[0]" },
    }) |fixture| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator,
            \\import "tools" as direct
            \\events := direct.values
            \\early()
            \\{s}
            \\fn early() -> int
            \\    return {s}
            \\end
            \\fn effect() -> int
            \\    direct.values[0] = 99
            \\    return 9
            \\end
        , .{ fixture.imported, fixture.expression });
        defer std.testing.allocator.free(input);
        var marker: u8 = 0;
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "facade-order.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "not initialized") != null);
        try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("events").?.list.items()[0].int);
    };
}
