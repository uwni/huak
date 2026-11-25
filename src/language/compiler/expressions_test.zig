//! Tests of diagnostics, dynamic types, ranges, unary operators, string ordering, depth limits and drawing instances.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const testing = @import("testing.zig");
const compile = compilation.compile;
const testGlobalType = testing.testGlobalType;

test "compile errors identify invalid symbols types and control flow" {
    const cases = [_][]const u8{ "x:=missing\n", "x:wrong:=1\n", "break\n", "return 1\n", "param n:int=2\nn=3\n", "fn f(x:int)->int;return true;end\n", "x:=sin(1,2)\n", "fn f()->int;x:=2;end\n" };
    for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
        try std.testing.expect(diagnostic.?.text().len != 0);
    }
}

test "explicit and dynamic any values do not acquire a later incidental type" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\a:any:=1
        \\a="later"
        \\b:=[1][0]
        \\b="later"
        \\result:=echo(1)
        \\fn echo(x:any)->any
        \\  x="changed"
        \\  return x
        \\end
    , "dynamic.huak", .{}, &diagnostic);
    defer program.deinit();
    for (program.global_types) |kind| try std.testing.expectEqual(Type.any, kind);
    try std.testing.expectEqual(Type.any, program.functions[1].local_types[0]);
}

test "range inference preserves dynamic bounds and known integer or floating types" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\values:=[1,2,1]
        \\for a in values[0]:2 do; end
        \\for b in 1:values[1] do; end
        \\for c in 1:values[2]:2 do; end
        \\for d in 1.0:values[1] do; end
        \\for e in 1:2 do; end
        \\for f in 1:0.5:2 do; end
    , "range-types.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqualSlices(Type, &.{.list}, program.global_types);
    try std.testing.expectEqualSlices(Type, &.{ .any, .any, .any, .any, .int, .number }, program.functions[program.entry].local_types[0..6]);
}

test "unary positive preserves variable handles while negation produces linear expressions" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "import solver.{solver, unknown}\ns:=solver(); x:=unknown(s); positive:=+x; negative:=-x", "sign.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(Type.variable, testGlobalType(&program, "positive"));
    try std.testing.expectEqual(Type.linear, testGlobalType(&program, "negative"));
}

test "string ordering agrees with the VM typed comparison surface" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "ordered:=\"a\"<\"b\"\n", "strings.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(Type.boolean, program.global_types[0]);
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "ordered:=\"a\"<1\n", "strings.huak", .{}, &diagnostic));
}

test "long left associative trees report a compilation limit instead of exhausting the stack" {
    var input: std.array_list.Managed(u8) = .init(std.testing.allocator);
    defer input.deinit();
    try input.appendSlice("value:=1");
    for (0..2000) |_| try input.appendSlice("+1");
    try input.append('\n');
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input.items, "long.huak", .{}, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "compilation depth") != null);
}

test "drawing instances have a dedicated type and no last-object query" {
    const invalid = [_][]const u8{
        "picture.object_id(picture(640, 480))",
        "import picture.object_id",
        "animation.animate(picture(640, 480),1,\"opacity\",[[0,0],[1,1]])",
        "animation.motion(picture(640, 480),1,path((0,0),(10,0)),[[0,0],[1,1]])",
        "p:=picture(640, 480); n:int:=object.append(p, object.draw(path((0,0),(10,0))))",
        "p:=picture(640, 480); o:=object.append(p, object.draw(path((0,0),(10,0)))); n:=o+1",
    };
    for ([_]bool{ false, true }) |optimize| for (invalid) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "object-type.huak", .{ .optimize = optimize }, &diagnostic));
        try std.testing.expect(diagnostic != null);
    };
}
