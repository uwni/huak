//! Tests of record declarations, imports and aliases across modules.
const std = @import("std");
const source = @import("../source.zig");
const lexical = @import("../scope.zig");
const ModuleGraph = @import("../ModuleGraph.zig");

test "local structs occupy callable and type channels without leaking fields into value scope" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("root.huak",
        \\made:=Style(width:2)
        \\export struct Style
        \\    width:float=1
        \\    label:string
        \\end
        \\struct Private
        \\    hidden:int
        \\end
        \\export Private
    );
    const unit = graph.units.items[0];
    const resolver = unit.resolver();
    const style = resolver.typeSymbol(0, "Style").?;
    try std.testing.expectEqual(lexical.Kind.record, style.identity.kind);
    try std.testing.expect(lexical.sameIdentity(style.identity, resolver.callable(0, "Style").member.?.identity));
    try std.testing.expect(lexical.sameIdentity(style.identity, unit.public_names.get("Style").?.identity));
    try std.testing.expectEqual(lexical.Kind.record, unit.public_names.get("Private").?.identity.kind);
    for ([_][]const u8{ "width", "label", "hidden" }) |field| {
        try std.testing.expect(resolver.readable(0, field) == null);
        try std.testing.expect(resolver.callable(0, field).member == null);
        try std.testing.expect(resolver.typeSymbol(0, field) == null);
    }
    try std.testing.expectEqualStrings("Style", unit.script.statements[0].value.assignment.value.value.call.name);
}

test "record aliases and reexports retain the original nominal declaration identity" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            if (std.mem.eql(u8, path, "base")) return .{ .name = "base.huak", .source = "export struct Style;width:float=1;end\nmixfix(Style) Style width _ in unary\nstruct Hidden;value:int;end" };
            return .{ .name = "bridge.huak", .source = "import \"base\".Style as Pen;export Pen" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "bridge".Pen as Paint
        \\import "base".Style as Paint
        \\import "base".*
        \\import "base" as styles
        \\fn paint(style:styles.Style)->Paint return style end
        \\export Paint
        \\created:=Style width 2
    );
    const root_source = graph.units.items[0];
    const bridge = graph.units.items[1];
    const base = graph.units.items[2];
    const original = base.public_names.get("Style").?.identity;
    try std.testing.expect(root_source.public_names.get("Paint").?.mixfix[0] != null);
    try std.testing.expect(root_source.script.statements[6].value.assignment.value.value == .mixfix_call);
    try std.testing.expectEqual(lexical.Kind.record, original.kind);
    try std.testing.expectEqual(base.index, original.module);
    try std.testing.expect(lexical.sameIdentity(original, bridge.public_names.get("Pen").?.identity));
    try std.testing.expect(lexical.sameIdentity(original, root_source.public_names.get("Paint").?.identity));
    for ([_][]const u8{ "Paint", "Style" }) |alias| {
        try std.testing.expect(lexical.sameIdentity(original, root_source.resolver().typeSymbol(0, alias).?.identity));
        try std.testing.expect(lexical.sameIdentity(original, root_source.resolver().callable(0, alias).member.?.identity));
    }
    try std.testing.expectEqual(base.index, root_source.resolver().namespace(0, "styles").?);
    try std.testing.expect(root_source.resolver().typeSymbol(0, "Hidden") == null);
    try std.testing.expectEqualStrings("styles.Style", root_source.script.statements[4].value.function.params[0].annotation.name);
}

test "different modules keep same-named records nominally distinct and reject conflicting aliases" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = path, .source = "export struct Style;value:int;end" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak", "import \"first\".Style as First;import \"second\".Style as Second");
    const resolver = graph.units.items[0].resolver();
    const first = resolver.typeSymbol(0, "First").?.identity;
    const second = resolver.typeSymbol(0, "Second").?.identity;
    try std.testing.expect(!lexical.sameIdentity(first, second));
    try std.testing.expectEqualStrings(first.name, second.name);
    var conflicting = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try std.testing.expectError(error.LanguageError, conflicting.root("conflict.huak", "import \"first\".Style;import \"second\".Style"));
    try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "conflicting imported name") != null);
}

test "record import type and callable channels follow lexical shadowing" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = path, .source = "export struct Style;value:int;end" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "outer".Style
        \\if true then
        \\    before:=Style(1)
        \\    import "inner".Style
        \\else
        \\    other:=Style(2)
        \\end
        \\after:=Style(3)
    );
    const unit = graph.units.items[0];
    const resolver = unit.resolver();
    const outer = resolver.typeSymbol(0, "Style").?.identity;
    const conditional = unit.script.statements[1].value.conditional;
    const inside_scope = unit.scopeAt(conditional.branches[0].body[0].span.start);
    const inside = resolver.typeSymbol(inside_scope, "Style").?.identity;
    try std.testing.expect(!lexical.sameIdentity(outer, inside));
    try std.testing.expect(lexical.sameIdentity(inside, resolver.callable(inside_scope, "Style").member.?.identity));
    const sibling_scope = unit.scopeAt(conditional.otherwise[0].span.start);
    try std.testing.expect(lexical.sameIdentity(outer, resolver.typeSymbol(sibling_scope, "Style").?.identity));
    try std.testing.expect(lexical.sameIdentity(outer, resolver.typeSymbol(unit.scopeAt(unit.script.statements[2].span.start), "Style").?.identity));
}

test "private records and duplicate local or imported record declarations are rejected" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = "library.huak", .source = "export struct Style;value:int;end\nstruct Hidden;value:int;end" };
        }
    };
    for ([_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "import \"library\".Hidden", .message = "does not export 'Hidden'" },
        .{ .input = "struct Style;value:int;end\nstruct Style;other:int;end", .message = "duplicate struct 'Style'" },
        .{ .input = "import \"library\".Style\nstruct Style;value:int;end", .message = "conflicting imported name 'Style'" },
        .{ .input = "struct Style;value:int;end\nimport \"library\".Style", .message = "conflicting imported name 'Style'" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var context: u8 = 0;
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", case.input));
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), case.message) != null);
    }
}
