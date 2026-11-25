//! File-independent source graph. The host resolves paths and owns filesystem policy.
const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("Parser.zig");
const source = @import("source.zig");
const builtins = @import("builtin.zig");
pub const lexical = @import("scope.zig");
const Namespace = builtins.Namespace;
const loading = @import("module_graph/loading.zig");

pub const ResolvedSource = struct { name: []const u8, source: []const u8 };
pub const ImportResolver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub inline fn resolve(self: ImportResolver, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) anyerror!ResolvedSource {
        return self.vtable.resolve(self.ptr, allocator, importer, path);
    }

    pub const VTable = struct {
        resolve: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!ResolvedSource,
    };
};

pub const Import = struct { scope: Parser.ScopeId, form: ast.ImportForm, initializer: u32, target: u32, span: source.Span };
pub const PublicSymbol = struct { identity: lexical.Identity, mixfix: [2]?*const ast.MixfixForm = .{ null, null } };
pub const Unit = struct {
    pub const data_export = "value";
    index: u32,
    name: []const u8,
    source_text: []const u8,
    script: ast.Script,
    headers: Parser.Headers,
    scopes: []lexical.Symbols,
    imports: std.ArrayList(Import) = .empty,
    public_names: std.StringHashMapUnmanaged(PublicSymbol) = .{},
    loading: bool = true,
    native_namespace: ?Namespace = null,
    data: ?@import("types.zig").Value = null,

    pub fn resolver(self: *const Unit) lexical.Resolver {
        return .{ .headers = &self.headers, .symbols = self.scopes };
    }
    pub fn resolverAt(self: *const Unit, position: usize) lexical.Resolver {
        return .{ .headers = &self.headers, .symbols = self.scopes, .position = position };
    }
    pub fn scopeAt(self: *const Unit, offset: usize) Parser.ScopeId {
        return self.headers.scopeAt(offset);
    }

    pub fn publicTemplate(self: *const Unit, head: []const u8, role: usize) ?Parser.MixfixLookup.Binding {
        const scoped = self.scopes[0].get(head) orelse return null;
        const binding = scoped.operators[role] orelse return null;
        if (self.public_names.get(binding.name)) |entry| {
            if (entry.mixfix[role] == binding.form) return .{ .form = binding.form.*, .target = binding.name };
        }
        // A module can re-export the same callable under a different name.
        var exports = self.public_names.iterator();
        while (exports.next()) |entry| {
            if (entry.value_ptr.mixfix[role] == binding.form) return .{ .form = binding.form.*, .target = entry.key_ptr.* };
        }
        return null;
    }
};
const ModuleGraph = @This();

allocator: std.mem.Allocator,
syntax: std.mem.Allocator,
options: Parser.Options,
resolver: ?ImportResolver,
diagnostic: *?source.Diagnostic,
units: std.ArrayList(*Unit) = .empty,
order: std.ArrayList(u32) = .empty,
names: std.StringHashMapUnmanaged(u32) = .{},

pub fn init(allocator: std.mem.Allocator, syntax: std.mem.Allocator, options: Parser.Options, resolver: ?ImportResolver, diagnostic: *?source.Diagnostic) ModuleGraph {
    return .{ .allocator = allocator, .syntax = syntax, .options = options, .resolver = resolver, .diagnostic = diagnostic };
}
pub fn root(self: *ModuleGraph, name: []const u8, text: []const u8) !void {
    _ = try loading.load(self, .{ .name = name, .source = text }, 0, null);
}
/// Namespaces remain compile-time references to canonical modules.
pub fn exportedNamespace(self: *const ModuleGraph, module: u32, name: []const u8) ?u32 {
    if (module >= self.units.items.len) return null;
    const exported = self.units.items[module].public_names.get(name) orelse return null;
    return if (exported.identity.kind == .namespace) exported.identity.module else null;
}
pub fn resolveNamespace(self: *const ModuleGraph, unit: *const Unit, initial: Parser.ScopeId, name: []const u8) ?u32 {
    return self.resolveNamespaceAt(unit, initial, name, std.math.maxInt(usize));
}
pub fn resolveNamespaceAt(self: *const ModuleGraph, unit: *const Unit, initial: Parser.ScopeId, name: []const u8, position: usize) ?u32 {
    var parts = std.mem.splitScalar(u8, name, '.');
    var target = unit.resolverAt(position).namespace(initial, parts.first()) orelse return null;
    while (parts.next()) |part| target = self.exportedNamespace(target, part) orelse return null;
    return target;
}

pub fn fail(self: *ModuleGraph, unit: *const Unit, span: source.Span, comptime format: []const u8, args: anytype) error{LanguageError} {
    const detail = source.Diagnostic.set(self.diagnostic, span, format, args);
    detail.setSource(unit.name, unit.source_text);
    return error.LanguageError;
}

test "exported namespaces retain canonical identities through nested imports" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "package")) return .{ .name = "package.huak", .source =
            \\import "tools" as tools
            \\export tools
            \\import "private" as hidden
            \\export fn ordinary()->int;return 1;end
            };
            if (std.mem.eql(u8, path, "tools")) return .{ .name = "tools.huak", .source =
            \\import math as numeric
            \\export numeric
            \\mixfix(wrap) wrap _ with _ in unary
            \\export fn wrap(x:int,extra:int=0)->int;return x+extra;end
            };
            if (std.mem.eql(u8, path, "private")) return .{ .name = "private.huak", .source = "export secret:=1" };
            return error.MissingModule;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "package".tools as first
        \\import "package".tools as second
        \\import "package".tools.numeric.{sin as sine, PI as pi}
        \\import "package".tools.*
        \\export first, second
        \\value:=wrap 2
        \\import "package" as package
        \\qualified:=package.tools.wrap 3
        \\templated:=package.tools.wrap 4 with 0
    );
    const unit = graph.units.items[0];
    const first = unit.public_names.get("first").?.identity;
    const second = unit.public_names.get("second").?.identity;
    try std.testing.expectEqual(lexical.Kind.namespace, first.kind);
    try std.testing.expect(lexical.sameIdentity(first, second));
    try std.testing.expectEqualStrings("tools.huak", first.name);
    try std.testing.expectEqual(first.module, unit.resolver().namespace(0, "first").?);
    const numeric = graph.resolveNamespace(unit, 0, "first.numeric").?;
    try std.testing.expectEqual(Namespace.math, graph.units.items[numeric].native_namespace.?);
    try std.testing.expectEqual(numeric, graph.exportedNamespace(first.module, "numeric").?);
    try std.testing.expectEqual(numeric, unit.imports.items[2].target);
    try std.testing.expectEqualStrings("package.huak", graph.units.items[unit.imports.items[2].initializer].name);
    try std.testing.expect(unit.resolver().callable(0, "sine").member != null);
    try std.testing.expect(unit.resolver().readable(0, "pi").?.imported == .member);
    try std.testing.expect(unit.resolver().callable(0, "wrap").member.?.mixfix[0] != null);
    const qualified = unit.script.statements[7].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("package.tools", qualified.operator.namespace.?);
    const templated = unit.script.statements[8].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("package.tools", templated.operator.namespace.?);
    try std.testing.expect(graph.resolveNamespace(unit, 0, "first.hidden") == null);
    try std.testing.expect(graph.resolveNamespace(unit, 0, "first.wrap") == null);

    const invalid = [_][]const u8{
        "import \"package\".hidden.secret",
        "import \"package\".ordinary.member",
        "import \"package\".tools.numeric.private",
        "import \"package\".tools as first;first:=1",
        "import \"package\".tools as first;import \"package\".tools.numeric as first",
    };
    for (invalid) |input| {
        var rejected = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, rejected.root("rejected.huak", input));
        try std.testing.expect(diagnostic != null);
    }
}

fn namespaceAllocationCase(allocator: std.mem.Allocator) !void {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "package.huak", .source = "import math as numeric;export numeric" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak", "import \"package\".numeric.{sin as sine, PI};import \"package\".numeric as numeric;export numeric");
    try std.testing.expect(graph.resolveNamespace(graph.units.items[0], 0, "numeric") != null);
}

test "namespace paths and exports release every partial allocation" {
    try namespaceAllocationCase(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), namespaceAllocationCase, .{});
}

test {
    _ = @import("module_graph/loading.zig");
    _ = @import("module_graph/symbols.zig");
    _ = @import("module_graph/exports.zig");
    _ = @import("module_graph/MixfixContext.zig");
    _ = @import("module_graph/records_test.zig");
    _ = @import("module_graph/native_test.zig");
}
