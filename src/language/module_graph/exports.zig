//! The public export identities of a unit.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const builtins = @import("../builtin.zig");
const lexical = @import("../scope.zig");
const ModuleGraph = @import("../ModuleGraph.zig");

pub fn collectPublicExports(self: *ModuleGraph, unit: *ModuleGraph.Unit) !void {
    var functions: std.StringHashMapUnmanaged(void) = .{};
    var groups: std.StringHashMapUnmanaged(void) = .{};
    defer functions.deinit(self.syntax);
    defer groups.deinit(self.syntax);
    for (unit.script.statements) |statement| switch (statement.value) {
        .function => |function| try functions.put(self.syntax, function.name, {}),
        .precedence_group => |group| try groups.put(self.syntax, group.name, {}),
        else => {},
    };
    for (unit.script.statements) |statement| switch (statement.value) {
        .exported => |declaration| {
            for (declaration.names) |name| try publicExport(self, unit, name.name, name.span, null, &functions, &groups);
        },
        .function => |function| if (function.exported) {
            try publicExport(self, unit, function.name, statement.span, .function, &functions, &groups);
        },
        .expand_block => |block| if (block.exported) {
            try publicExport(self, unit, block.name, statement.span, .block, &functions, &groups);
        },
        .structure => |structure| if (structure.exported) {
            try publicExport(self, unit, structure.name, statement.span, .record, &functions, &groups);
        },
        else => {},
    };
}

fn publicExport(self: *ModuleGraph, unit: *ModuleGraph.Unit, name: []const u8, span: source.Span, explicit_kind: ?lexical.Kind, functions: *const std.StringHashMapUnmanaged(void), groups: *const std.StringHashMapUnmanaged(void)) !void {
    const resolver_ = unit.resolverAt(span.start);
    var identity: lexical.Identity = .{ .module = unit.index, .name = name, .kind = .unknown };
    if (explicit_kind) |kind| {
        identity.kind = kind;
    } else if (resolver_.readable(0, name)) |readable| {
        switch (readable) {
            .ordinary => identity.kind = .value,
            .imported => |imported| switch (imported) {
                .member => |member| identity = member.identity,
                .namespace => |module| identity = .{ .module = module, .name = self.units.items[module].name, .kind = .namespace },
            },
        }
    }
    const call: lexical.Callable = if (identity.kind == .value or identity.kind == .namespace) .{} else resolver_.callable(0, name);
    if (identity.kind == .unknown) {
        if (functions.contains(name)) identity.kind = .function else if (call.member) |member| identity = member.identity else if (groups.contains(name)) identity.kind = .precedence else if (resolver_.precedence(0, name)) |member| identity = member.identity;
    }
    if (identity.kind == .unknown) if (if (unit.native_namespace) |namespace| builtins.namespaceLookup(namespace, name) else builtins.lookup(name)) |signature| {
        if (!(unit.native_namespace != null and unit.native_namespace == signature.namespace) and !signature.implicit) return self.fail(unit, span, "builtin '{s}' must be explicitly imported before it can be exported", .{name});
        identity = .{ .module = std.math.maxInt(u32), .name = @tagName(signature.id), .kind = .builtin };
    };
    if (identity.kind == .unknown) return self.fail(unit, span, "unknown exported variable or function '{s}'", .{name});
    const callable = identity.kind == .function or identity.kind == .builtin or identity.kind == .record;
    var forms: [2]?*const ast.MixfixForm = .{ null, null };
    if (callable) for (0..2) |index| {
        forms[index] = if (call.mixfix[index]) |value| value else if (call.member) |member| member.mixfix[index] else null;
    };
    try unit.public_names.put(self.syntax, name, .{ .identity = identity, .mixfix = forms });
}

test "a global export does not disclose a same-named private prefix function" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = "library.huak", .source =
            \\mixfix(same) same _ in unary
            \\fn same(x:int)->int;return x;end
            \\same:=0; if true then;same=3;end
            \\export same
            };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak", "import \"library\" as lib\nx:=lib.same+1");
    const expression = graph.units.items[0].script.statements[1].value.assignment.value.value.binary;
    try std.testing.expectEqual(ast.Binary.add, expression.op);
    try std.testing.expectEqualStrings("same", expression.left.value.member.name);
    try std.testing.expect(graph.units.items[1].public_names.get("same").?.mixfix[0] == null);
}

test "ordinary sources cannot reexport unimported domain functions" {
    for ([_][]const u8{ "export sin", "export rgb", "export circle", "export draw" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "must be explicitly imported") != null);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("custom.huak", "export fn sin(x:float)->float return x end");
    try std.testing.expectEqual(lexical.Kind.function, graph.units.items[0].public_names.get("sin").?.identity.kind);
}

test "core primitives and constructors can be reexported without imports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("root.huak", "export print,panic,len,int,float,str,vec2,vec3,dict_contains,dict_remove,keys,copy,path,pen,picture,object,solver");
    const root_source = graph.units.items[0];
    for (builtins.signatures) |signature| {
        if (signature.implicit) {
            const exported = root_source.public_names.get(signature.name).?;
            try std.testing.expectEqual(lexical.Kind.builtin, exported.identity.kind);
        } else try std.testing.expect(root_source.public_names.get(signature.name) == null);
    }
    try std.testing.expectEqual(@as(usize, 1), graph.units.items.len);
}

test "public export identities use bindings visible at the export declaration" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = "library.huak", .source = "export fn f()->int;return 2;end" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    const resolver_: ModuleGraph.ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, resolver_, &diagnostic);
    try graph.root("root.huak", "fn f()->int;return 1;end;export f;import \"library\".f");
    const exposed = graph.units.items[0].public_names.get("f").?.identity;
    try std.testing.expectEqual(@as(u32, 0), exposed.module);
    try std.testing.expectEqual(lexical.Kind.function, exposed.kind);
    for ([_][]const u8{ "export f;import \"library\".f", "export library;import \"library\" as library" }) |input| {
        var rejected = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, resolver_, &diagnostic);
        try std.testing.expectError(error.LanguageError, rejected.root("early-export.huak", input));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "unknown exported variable or function") != null);
    }
}
