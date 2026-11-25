//! Tests of exports, the default output, and export modifiers on functions and records.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const ModuleGraph = @import("../ModuleGraph.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const ImportResolver = ModuleGraph.ImportResolver;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const testing = @import("testing.zig");
const compile = compilation.compile;
const testGlobalType = testing.testGlobalType;

test "imported global exports retain value syntax over a same-named private prefix" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "dependency.huak", .source =
            \\fn same(x:int)->int;return x;end
            \\mixfix(same) same _ in unary
            \\same:=0; if true then;same=3;end
            \\export same
            };
        }
    };
    var context: u8 = 0;
    const resolver: ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, "import \"dependency\" as values\nanswer:=values.same+1", "root.huak", .{ .optimize = optimize, .import_resolver = resolver }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 4), machine.getGlobal("answer").?.int);
    }
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "import \"dependency\" as values\nanswer:=values.same(1)", "private-call.huak", .{ .import_resolver = resolver }, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "not callable") != null);
}

test "exports retain named global visibility without adding execution instructions" {
    var diagnostic: ?Diagnostic = null;
    var exported = try compile(std.testing.allocator,
        \\export later
        \\export title:="first"
        \\later:=3
        \\title="last"
        \\hidden:=7
    , "exports.huak", .{}, &diagnostic);
    defer exported.deinit();
    var ordinary = try compile(std.testing.allocator,
        \\title:="first"
        \\later:=3
        \\title="last"
        \\hidden:=7
    , "ordinary.huak", .{}, &diagnostic);
    defer ordinary.deinit();
    try std.testing.expectEqual(@as(usize, 2), exported.exports.len);
    try std.testing.expectEqualStrings("later", exported.exports[0].name);
    try std.testing.expectEqualStrings("title", exported.exports[1].name);
    for (exported.exports) |item| {
        try std.testing.expectEqualStrings(item.name, exported.global_names[item.target.global]);
        try std.testing.expect(std.mem.startsWith(u8, exported.source_text[item.span.start..item.span.end], "export "));
    }
    try std.testing.expectEqualSlices(Type, ordinary.global_types, exported.global_types);
    try std.testing.expectEqual(ordinary.constants.len, exported.constants.len);
    for (ordinary.constants, exported.constants) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
    const ordinary_code = ordinary.functions[0].code;
    const exported_code = exported.functions[0].code;
    try std.testing.expectEqual(ordinary_code.len, exported_code.len);
    for (ordinary_code, exported_code) |expected, actual| {
        try std.testing.expectEqual(expected.op, actual.op);
        try std.testing.expectEqual(expected.a, actual.a);
        try std.testing.expectEqual(expected.b, actual.b);
    }
}

test "exports reject duplicate unknown and non-top-level declarations" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "export missing", .message = "unknown exported variable" },
        .{ .code = "export f\nfn other();end", .message = "unknown exported variable" },
        .{ .code = "export x:=1;export x", .message = "duplicate export" },
        .{ .code = "default picture();default picture()", .message = "duplicate default output" },
        .{ .code = "if true then;export x:=1;end", .message = "script top level" },
        .{ .code = "while false do;export x:=1;end", .message = "script top level" },
        .{ .code = "for i in 1:2 do;export x:=i;end", .message = "script top level" },
        .{ .code = "fn f();export x:=1;end", .message = "script top level" },
        .{ .code = "fn f();default 1;end", .message = "script top level" },
        .{ .code = "export fn f();end;export f", .message = "duplicate export" },
        .{ .code = "x:=1;export x,x", .message = "duplicate export" },
        .{ .code = "x:=1;export x,missing", .message = "unknown exported variable" },
        .{ .code = "if true then;export fn f();end;end", .message = "script top level" },
        .{ .code = "fn f();export fn nested();end;end", .message = "script top level" },
        .{ .code = "export plate:=1;export plate;default plate", .message = "duplicate export" },
        .{ .code = "if true then;export plate:=1;default plate;end", .message = "script top level" },
    };
    for (cases) |case| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.code, "invalid-export.huak", .{}, &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "default output is picture-only and independent from module exports" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "private:=picture(); default private", "output.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 0), program.exports.len);
    try std.testing.expectEqual(@as(usize, 2), program.outputs.len);
    try std.testing.expectEqualStrings("private", program.outputs[0].name);
    try std.testing.expectEqualStrings("default", program.outputs[1].name);
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "default 1", "invalid.huak", .{}, &diagnostic));
}

test "function export modifiers and mixed export lists reuse ordinary compilation" {
    const modified =
        \\precedence stage below addition; above path; associativity left end
        \\mixfix(double) double _ in unary
        \\mixfix(combined) _ combined _ in stage
        \\export fn double(x:int)->int return x*2 end
        \\fn combined(a:int,b:int)->int return a*10+b end
        \\value:=double(3)
        \\export value,combined,stage
    ;
    const ordinary =
        \\precedence stage below addition; above path; associativity left end
        \\mixfix(double) double _ in unary
        \\mixfix(combined) _ combined _ in stage
        \\fn double(x:int)->int return x*2 end
        \\fn combined(a:int,b:int)->int return a*10+b end
        \\value:=double(3)
        \\export double
        \\export value
        \\export combined
        \\export stage
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var direct = try compile(std.testing.allocator, modified, "modified.huak", .{ .optimize = optimize }, &diagnostic);
        defer direct.deinit();
        var separate = try compile(std.testing.allocator, ordinary, "ordinary.huak", .{ .optimize = optimize }, &diagnostic);
        defer separate.deinit();
        try std.testing.expectEqual(@as(usize, 4), direct.exports.len);
        try std.testing.expectEqual(direct.exports[0].mixfix[0].?.group, separate.exports[0].mixfix[0].?.group);
        try std.testing.expectEqual(direct.exports[2].mixfix[1].?.group, separate.exports[2].mixfix[1].?.group);
        for (direct.exports, separate.exports) |actual, expected| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqualDeep(expected.target, actual.target);
        }
        for (direct.functions, separate.functions) |actual, expected| {
            try std.testing.expectEqual(expected.code.len, actual.code.len);
            for (actual.code, expected.code) |a, b| {
                try std.testing.expectEqual(b.op, a.op);
                try std.testing.expectEqual(b.a, a.a);
                try std.testing.expectEqual(b.b, a.b);
            }
        }
    }
}

test "struct export modifiers retain nominal constructors beside value bindings through aliases" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "library")) return .{ .name = "library.huak", .source = "S:=42\nexport struct S\n value:int=5\nend\nexport number:=S" };
            return .{ .name = "bridge.huak", .source = "import \"library\".S as Renamed\nexport Renamed" };
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var context: u8 = 0;
        var program = try compile(std.testing.allocator,
            \\import "library" as types
            \\import "library".S as Alias
            \\import "bridge".Renamed as Reexport
            \\local:Alias:=Alias()
            \\qualified:types.S:=types.S(value:9)
            \\again:Reexport:=Reexport()
            \\copied_qualified:=copy(types.S(value:11))
            \\copied_alias:=copy(Alias(value:12))
            \\first:=local.value; second:=qualified.value; third:=again.value
            \\copied_first:=copied_qualified.value; copied_second:=copied_alias.value
            \\number:=types.number
            \\export Alias, Reexport
        , "constructor-export.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        try std.testing.expect(program.exports[0].target == .record);
        try std.testing.expectEqualDeep(program.exports[0].target, program.exports[1].target);
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "qualified"));
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "again"));
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "copied_qualified"));
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "copied_alias"));
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 5), machine.getGlobal("first").?.int);
        try std.testing.expectEqual(@as(i64, 9), machine.getGlobal("second").?.int);
        try std.testing.expectEqual(@as(i64, 5), machine.getGlobal("third").?.int);
        try std.testing.expectEqual(@as(i64, 42), machine.getGlobal("number").?.int);
        try std.testing.expectEqual(@as(i64, 11), machine.getGlobal("copied_first").?.int);
        try std.testing.expectEqual(@as(i64, 12), machine.getGlobal("copied_second").?.int);
        var bare = try compile(std.testing.allocator, "struct S value:int end\nS:=42\nexport S", "value-export.huak", .{ .optimize = optimize }, &diagnostic);
        defer bare.deinit();
        try std.testing.expect(bare.exports[0].target == .global);
    }
}

test "forward constructor references to nested structs fail before reading module exports" {
    for ([_]bool{ false, true }) |optimize| {
        for ([_][]const u8{
            "fn f()->any\n return Local()\n struct Local\n value:int\n end\nend",
            "if true then\n result:=Local()\n struct Local\n value:int\n end\nend",
        }) |input| {
            var diagnostic: ?Diagnostic = null;
            try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "nested-struct.huak", .{ .optimize = optimize }, &diagnostic));
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "top level") != null);
        }
    }
}
