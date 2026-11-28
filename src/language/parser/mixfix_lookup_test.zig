//! Tests of finding prefix and mixfix declarations: before their position, in coordinate groups, qualified, per block, and through providers.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const MixfixLookup = Parser.MixfixLookup;
const Options = Parser.Options;

test "prefix declarations are available before their source position and preserve explicit calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\x:=wrap 1+2
        \\mixfix(wrap) wrap _ in addition
        \\ordinary:=wrap(1+2)
        \\spaced:=wrap (1+2)
        \\grouped:=(wrap)(1)
        \\mixed:=wrap a shifted b+2
        \\wrap:=3
    , .{}, &diagnostic);
    const script = try parser.parse();
    const first = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("wrap", first.operator.name);
    try std.testing.expectEqual(ast.Binary.add, first.args[0].value.binary.op);
    try std.testing.expectEqualStrings("wrap", script.statements[1].value.mixfix_binding.target.name);
    try std.testing.expectEqualStrings("wrap", script.statements[2].value.assignment.value.value.call.name);
    try std.testing.expectEqualStrings("wrap", script.statements[3].value.assignment.value.value.mixfix_call.operator.name);
    try std.testing.expect(script.statements[3].value.assignment.value.value.mixfix_call.args[0].value == .grouped);
    try std.testing.expectEqualStrings("wrap", script.statements[4].value.assignment.value.value.call.name);
    const mixed = script.statements[5].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("wrap", mixed.args[0].value.mixfix_call.operator.name);
    try std.testing.expectEqualStrings("shifted", mixed.operator.name);
    try std.testing.expectEqualStrings("wrap", script.statements[6].value.assignment.name);
}

test "spaced prefix coordinate groups work in drawing and qualified calls" {
    const Lookup = struct {
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            if (leading) return null;
            const matches = if (name.namespace) |ns|
                std.mem.eql(u8, ns, "paint") and std.mem.eql(u8, name.name, "sphere")
            else
                std.mem.eql(u8, name.name, "draw") or std.mem.eql(u8, name.name, "fill");
            return if (matches) .{ .form = .{ .head = name.name, .parts = &.{null}, .group = .{ .name = "unary", .span = name.span } } } else null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    var parser = try Parser.init(arena.allocator(),
        \\block
        \\    draw (0,0)--(10,10)
        \\    fill (0,0)--(10,0)--(10,10)--cycle
        \\    object.append(pic, draw(curve))
        \\end
        \\spaced:=paint.sphere (1+2)
        \\ordinary:=paint.sphere(1+2)
        \\unbound:=plain (1+2)
    , .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    const statements = script.statements[0].value.expression.value.block;
    for (statements[0..2]) |stmt| {
        const call = stmt.value.expression.value.mixfix_call;
        try std.testing.expect(call.args[0].value == .path_join);
    }
    try std.testing.expect(statements[2].value.expression.value == .call);
    const spaced = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("paint", spaced.operator.namespace.?);
    try std.testing.expectEqualStrings("sphere", spaced.operator.name);
    try std.testing.expect(script.statements[2].value.assignment.value.value == .call);
    try std.testing.expect(script.statements[3].value.assignment.value.value == .call);
}

test "qualified prefix lookup preserves namespaced ordinary calls" {
    const Lookup = struct {
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            const matches = !leading and name.namespace != null and std.mem.eql(u8, name.namespace.?, "tools") and std.mem.eql(u8, name.name, "wrap");
            return if (matches) .{ .form = .{ .head = name.name, .parts = &.{null}, .group = .{ .name = "unary", .span = name.span } } } else null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    var parser = try Parser.init(arena.allocator(),
        \\x:=tools.wrap -2^2
        \\y:=tools.wrap(2)
        \\z:=tools.image
    , .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    const first = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("tools", first.operator.namespace.?);
    try std.testing.expectEqualStrings("wrap", first.operator.name);
    try std.testing.expectEqual(ast.Unary.negate, first.args[0].value.unary.op);
    try std.testing.expect(script.statements[1].value.assignment.value.value.call.dot);
    try std.testing.expectEqualStrings("image", script.statements[2].value.assignment.value.value.member.name);
}

test "standalone prefix discovery respects block boundaries and callable data namespaces" {
    const input =
        \\fn f()
        \\    if true then
        \\        mixfix(decorate) decorate _ in unary
        \\        decorate:=1
        \\        first:=decorate (2)
        \\    else
        \\        second:=decorate (3)
        \\    end
        \\    third:=decorate (4)
        \\end
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    const statements = script.statements[0].value.function.body;
    const conditional = statements[0].value.conditional;
    try std.testing.expect(conditional.branches[0].body[2].value.assignment.value.value == .mixfix_call);
    try std.testing.expect(conditional.otherwise[0].value.assignment.value.value == .call);
    try std.testing.expect(statements[1].value.assignment.value.value == .call);
}

test "mixfix callback null cannot be bypassed by header or drawing shortcuts" {
    const Lookup = struct {
        fn lookup(_: *anyopaque, _: ast.OperatorName, _: bool) ?MixfixLookup.Binding {
            return null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    var parser = try Parser.init(arena.allocator(), "mixfix(decorate) decorate _ in unary\nx:=decorate (1)\nblock draw (curve) end", .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    try std.testing.expect(script.statements[1].value.assignment.value.value == .call);
    try std.testing.expect(script.statements[2].value.expression.value.block[0].value.expression.value == .call);
}

test "mixfix providers support qualified names and reject malformed external templates" {
    const Lookup = struct {
        fn lookup(context: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            if (leading) return null;
            const form: *const ast.MixfixForm = @ptrCast(@alignCast(context));
            if (name.namespace != null and std.mem.eql(u8, name.namespace.?, "shapes") and std.mem.eql(u8, name.name, "make")) return .{ .form = form.* };
            return null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var form: ast.MixfixForm = .{ .head = "make", .parts = &.{ "with", "center", null, "radius", null }, .group = .{ .name = "unary", .span = .{ .start = 0, .end = 0 } } };
    const options: Options = .{ .mixfix = .{ .ptr = &form, .vtable = &.{ .lookup = Lookup.lookup } } };
    var parser = try Parser.init(arena.allocator(), "x:=shapes.make with center (0,0) radius 1", options, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("shapes", script.statements[0].value.assignment.value.value.mixfix_call.operator.namespace.?);
    form.parts = &.{ "with", null, null };
    parser = try Parser.init(arena.allocator(), "x:=shapes.make with 1", options, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "invalid mixfix template") != null);
}
