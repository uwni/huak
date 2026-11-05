//! File-independent source graph. The host resolves paths and owns filesystem policy.
const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("Parser.zig");
const source = @import("source.zig");
const DataFormat = @import("data.zig").Format;
const builtins = @import("builtin.zig");
pub const lexical = @import("scope.zig");
const Namespace = builtins.Namespace;

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

test "module graph exposes only exported prefix declarations while parsing callers" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (!std.mem.eql(u8, path, "library")) return error.UnknownModule;
            return .{ .name = "library.huak", .source =
            \\mixfix(wrap) wrap _ in addition
            \\export wrap
            \\fn wrap(x:int)->int;return x;end
            \\mixfix(hidden) hidden _ in addition
            \\fn hidden(x:int)->int;return x;end
            };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    const memory = arena.allocator();
    const resolver: ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    var graph = ModuleGraph.init(memory, memory, .{}, resolver, &diagnostic);
    try graph.root("root.huak", "import \"library\" as lib\nx:=lib.wrap 2+3\ny:=lib.wrap(4)\n");
    const script = graph.units.items[0].script;
    const call = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("lib", call.operator.namespace.?);
    try std.testing.expectEqualStrings("wrap", call.operator.name);
    try std.testing.expect(script.statements[2].value.assignment.value.value.call.dot);
    const library = graph.units.items[1];
    const form = &library.headers.operators[0].statement.value.mixfix_binding.form;
    try std.testing.expect(library.scopes[0].get("wrap").?.mixfix[0].? == form);
    try std.testing.expect(library.public_names.get("wrap").?.mixfix[0].? == form);
    var private_graph = ModuleGraph.init(memory, memory, .{}, resolver, &diagnostic);
    try std.testing.expectError(error.LanguageError, private_graph.root("private.huak", "import \"library\" as lib\nx:=lib.hidden 2\n"));
    try std.testing.expectEqualStrings("private.huak", diagnostic.?.fileName().?);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.position("").line);
}
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

    fn publicTemplate(self: *const Unit, head: []const u8, role: usize) ?Parser.MixfixLookup.Binding {
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
    _ = try self.load(.{ .name = name, .source = text }, 0, null);
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
fn load(self: *ModuleGraph, resolved: ResolvedSource, depth: usize, native: ?Namespace) anyerror!u32 {
    if (self.names.get(resolved.name)) |existing| {
        if (self.units.items[existing].native_namespace != native) return error.ReservedModuleIdentity;
        if (self.units.items[existing].loading) return error.CyclicImport;
        return existing;
    }
    if (native == null) for (std.enums.values(Namespace)) |namespace| {
        if (std.mem.eql(u8, resolved.name, namespace.moduleName())) return error.ReservedModuleIdentity;
    };
    if (depth > 128) return error.ImportDepthExceeded;
    if (self.units.items.len >= 1024) return error.TooManyModules;
    const name = try self.allocator.dupe(u8, resolved.name);
    const text = try self.allocator.dupe(u8, resolved.source);
    const format = if (depth != 0 and native == null) DataFormat.fromPath(name) else null;
    const headers: Parser.Headers = if (format != null) .{
        .scopes = &.{.{ .parent = null, .kind = .module, .body = .{ .start = 0, .end = 0 }, .ordinary_names = &.{} }},
        .imports = &.{},
        .operators = &.{},
    } else Parser.scanHeaders(self.syntax, text, self.options, self.diagnostic) catch |err| {
        if (self.diagnostic.*) |*detail| detail.setSource(name, text);
        return err;
    };
    const index: u32 = @intCast(self.units.items.len);
    const symbols = try self.syntax.alloc(lexical.Symbols, headers.scopes.len);
    @memset(symbols, .{});
    const unit = try self.syntax.create(Unit);
    unit.* = .{ .index = index, .name = name, .source_text = text, .script = .{ .statements = &.{} }, .headers = headers, .scopes = symbols, .native_namespace = native };
    try self.units.append(self.syntax, unit);
    try self.names.put(self.syntax, name, index);
    if (format) |data_format| {
        var offset: usize = 0;
        unit.data = data_format.decode(self.allocator, text, &offset) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fail(unit, .{ .start = offset, .end = @min(offset + 1, text.len) }, "invalid {s} data: {s}", .{ @tagName(data_format), @errorName(err) });
        };
    } else try self.parseScript(unit, depth);
    unit.loading = false;
    try self.order.append(self.syntax, index);
    return index;
}

fn parseScript(self: *ModuleGraph, unit: *Unit, depth: usize) anyerror!void {
    const headers = unit.headers;
    const name = unit.name;
    const text = unit.source_text;
    const index = unit.index;
    for (headers.records) |header| try self.bindRecord(unit, header.scope, header.statement);
    for (headers.expansions) |header| {
        const parent = headers.scopes[header.scope].parent orelse 0;
        if (parent != 0) return self.fail(unit, header.statement.span, "expand_block declarations must be at script top level", .{});
        const block_name = header.statement.value.expand_block.name;
        const entry = try self.symbol(unit, parent, block_name);
        if (entry.callable != null) return self.fail(unit, header.statement.span, "duplicate block '{s}'", .{block_name});
        entry.callable = .{ .module = index, .name = block_name, .identity = .{ .module = index, .name = block_name, .kind = .block } };
    }
    for (headers.imports) |header| {
        const statement = header.statement;
        const imported = statement.value.imported;
        if (imported.path.len == 0 or std.mem.indexOfScalar(u8, imported.path, 0) != null)
            return self.fail(unit, statement.span, "import path must be nonempty and contain no NUL bytes", .{});
        const imported_native = if (imported.bare) Namespace.parse(imported.path) else null;
        const bundled = if (imported.bare or std.mem.startsWith(u8, imported.path, "std/")) @import("huak_std").resolve(imported.path) else null;
        const child_source: ResolvedSource = if (imported_native) |namespace| native: {
            const canonical = namespace.moduleName();
            const native_source = if (self.names.get(canonical)) |existing| self.units.items[existing].source_text else try self.nativeSource(namespace);
            break :native .{ .name = canonical, .source = native_source };
        } else if (bundled) |entry| builtin: {
            break :builtin .{ .name = entry.name, .source = entry.source };
        } else local: {
            if (std.mem.startsWith(u8, imported.path, "std/"))
                return self.fail(unit, statement.span, "unknown standard library module '{s}'", .{imported.path});
            const resolver = self.resolver orelse return self.fail(unit, statement.span, "import requires a source resolver", .{});
            const path = if (imported.bare) try std.fmt.allocPrint(self.syntax, "{s}.huak", .{imported.path}) else imported.path;
            break :local resolver.resolve(self.syntax, name, path) catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.fail(unit, statement.span, "cannot import '{s}': {s}", .{ imported.path, @errorName(err) });
            };
        };
        var target = self.load(child_source, depth + 1, imported_native) catch |err| {
            if (err == error.ReservedModuleIdentity) return self.fail(unit, statement.span, "source resolver cannot use reserved native module identity", .{});
            if (err == error.CyclicImport) return self.fail(unit, statement.span, "cyclic import: '{s}' -> '{s}'", .{ std.fs.path.basename(name), std.fs.path.basename(child_source.name) });
            if (err == error.ImportDepthExceeded or err == error.TooManyModules) return self.fail(unit, statement.span, "import graph exceeds limits: {s}", .{@errorName(err)});
            return err;
        };
        const initializer = target;
        const is_data = self.units.items[target].data != null;
        if (is_data and (imported.form != .namespace or imported.namespace_path.len != 0))
            return self.fail(unit, statement.span, "a data file imports as one value; use an alias and index its contents", .{});
        for (imported.namespace_path) |part| {
            const exposed = self.units.items[target].public_names.get(part) orelse
                return self.fail(unit, statement.span, "module '{s}' does not export '{s}'", .{ self.units.items[target].name, part });
            if (exposed.identity.kind != .namespace)
                return self.fail(unit, statement.span, "export '{s}' is not a module namespace", .{part});
            target = exposed.identity.module;
        }
        if (imported.form == .selected) {
            var local_names: std.StringHashMapUnmanaged(void) = .{};
            defer local_names.deinit(self.syntax);
            for (imported.form.selected) |binding| {
                if (local_names.contains(binding.alias)) return self.fail(unit, binding.span, "duplicate imported name '{s}'", .{binding.alias});
                try local_names.put(self.syntax, binding.alias, {});
                if (!self.units.items[target].public_names.contains(binding.name))
                    return self.fail(unit, binding.span, "module '{s}' does not export '{s}'", .{ self.units.items[target].name, binding.name });
            }
        }
        try unit.imports.append(self.syntax, .{ .scope = header.scope, .form = imported.form, .initializer = initializer, .target = target, .span = statement.span });
        switch (imported.form) {
            .namespace => |alias| if (is_data) {
                const member: PublicSymbol = .{ .identity = .{ .module = target, .name = Unit.data_export, .kind = .value } };
                try self.bindMember(unit, header.scope, alias, target, initializer, Unit.data_export, member, statement.span);
            } else try self.bindNamespace(unit, header.scope, alias, target, initializer, statement.span),
            .all => {
                var exports = self.units.items[target].public_names.iterator();
                while (exports.next()) |entry| try self.bindMember(unit, header.scope, entry.key_ptr.*, target, initializer, entry.key_ptr.*, entry.value_ptr.*, statement.span);
            },
            .selected => |selected| for (selected) |binding| {
                const exposed = self.units.items[target].public_names.get(binding.name).?;
                try self.bindMember(unit, header.scope, binding.alias, target, initializer, binding.name, exposed, binding.span);
            },
        }
    }
    for (headers.operators) |header| {
        const binding = &header.statement.value.mixfix_binding;
        const qualified = binding.target.namespace != null;
        if (qualified) {
            binding.target.module = index;
            binding.form.group.module = index;
        } else {
            const entry = try self.symbol(unit, header.scope, binding.target.name);
            const role = &entry.mixfix[@intFromBool(binding.form.leading)];
            if (role.* != null) return self.fail(unit, header.statement.span, "duplicate mixfix binding '{s}'", .{binding.target.name});
            role.* = &binding.form;
        }
        try self.bindOperator(unit, header.scope, .{ .name = binding.target.name, .form = &binding.form, .qualified = if (qualified) binding else null }, header.statement.span);
    }
    var mixfix_context: MixfixContext = .{ .graph = self, .unit = unit };
    var options = self.options;
    options.mixfix = .{ .ptr = &mixfix_context, .vtable = &.{ .lookup = MixfixContext.lookup } };
    options.blocks = .{ .ptr = &mixfix_context, .vtable = &.{ .lookup = MixfixContext.block, .enter = MixfixContext.enterBlock } };
    var frontend = Parser.init(self.syntax, text, options, self.diagnostic) catch |err| {
        if (self.diagnostic.*) |*detail| detail.setSource(name, text);
        return err;
    };
    frontend.headers = headers;
    unit.script = frontend.parse() catch |err| {
        if (self.diagnostic.*) |*detail| detail.setSource(name, text);
        return err;
    };
    try self.collectPublicExports(unit);
}
fn nativeSource(self: *ModuleGraph, namespace: Namespace) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.syntax);
    for (builtins.signatures) |signature| {
        if (signature.namespace != namespace) continue;
        try text.appendSlice(self.syntax, "export ");
        try text.appendSlice(self.syntax, signature.name);
        try text.appendSlice(self.syntax, "\n");
    }
    for (builtins.constantNames(namespace)) |name| {
        const constant = (builtins.namespaceConstant(namespace, name) orelse unreachable).number;
        const declaration = try std.fmt.allocPrint(self.syntax, "export {s}:={d}\n", .{ name, constant });
        defer self.syntax.free(declaration);
        try text.appendSlice(self.syntax, declaration);
    }
    return text.toOwnedSlice(self.syntax);
}
fn symbol(self: *ModuleGraph, unit: *Unit, id: Parser.ScopeId, name: []const u8) !*lexical.Symbol {
    const table = &unit.scopes[id];
    const entry = try table.getOrPut(self.syntax, name);
    if (!entry.found_existing) {
        errdefer _ = table.remove(name);
        const stored = try self.syntax.create(lexical.Symbol);
        stored.* = .{};
        entry.value_ptr.* = stored;
    }
    return entry.value_ptr.*;
}
fn checkOrdinary(self: *ModuleGraph, unit: *Unit, id: Parser.ScopeId, name: []const u8, span: source.Span) !void {
    for (unit.headers.scopes[id].ordinary_names) |ordinary| if (std.mem.eql(u8, name, ordinary.name))
        return self.fail(unit, span, "name '{s}' conflicts with an imported binding in the same scope", .{name});
}
fn bindNamespace(self: *ModuleGraph, unit: *Unit, id: Parser.ScopeId, alias: []const u8, target: u32, initializer: u32, span: source.Span) !void {
    try self.checkOrdinary(unit, id, alias, span);
    const entry = try self.symbol(unit, id, alias);
    if (entry.callable) |callable| try self.checkNamespaceCallable(unit, target, alias, callable.identity, span);
    if (entry.value) |earlier| {
        if (earlier != .namespace or earlier.namespace != target) return self.fail(unit, span, "duplicate import namespace '{s}'", .{alias});
        if (span.end < entry.value_since) entry.namespace_initializer = initializer;
        entry.value_since = @min(entry.value_since, span.end);
    } else {
        entry.value = .{ .namespace = target };
        entry.namespace_initializer = initializer;
        entry.value_since = span.end;
    }
}
fn checkNamespaceCallable(self: *ModuleGraph, unit: *Unit, target: u32, name: []const u8, identity: lexical.Identity, span: source.Span) !void {
    const native = self.units.items[target].native_namespace;
    const constructor = if (native) |namespace| builtins.namespaceConstructor(namespace, name) else null;
    if (constructor == null or identity.kind != .builtin or !std.mem.eql(u8, @tagName(constructor.?.id), identity.name))
        return self.fail(unit, span, "namespace '{s}' conflicts with callable binding", .{name});
}
fn bindRecord(self: *ModuleGraph, unit: *Unit, id: Parser.ScopeId, statement: *const ast.Stmt) !void {
    const declaration = statement.value.structure;
    const entry = try self.symbol(unit, id, declaration.name);
    if (entry.callable != null or entry.type_symbol != null)
        return self.fail(unit, statement.span, "duplicate struct '{s}'", .{declaration.name});
    const member: lexical.Member = .{
        .module = unit.index,
        .name = declaration.name,
        .identity = .{ .module = unit.index, .name = declaration.name, .kind = .record },
    };
    entry.callable = member;
    entry.type_symbol = member;
}
fn bindMember(self: *ModuleGraph, unit: *Unit, id: Parser.ScopeId, alias: []const u8, target: u32, initializer: u32, name: []const u8, exposed: PublicSymbol, span: source.Span) !void {
    const member: lexical.Member = .{ .module = target, .name = name, .identity = exposed.identity, .mixfix = exposed.mixfix, .initializer = initializer };
    const entry = try self.symbol(unit, id, alias);
    switch (exposed.identity.kind) {
        .namespace => try self.bindNamespace(unit, id, alias, exposed.identity.module, initializer, span),
        .function, .block, .record, .builtin => {
            if (entry.value) |value| if (value == .namespace) try self.checkNamespaceCallable(unit, value.namespace, alias, exposed.identity, span);
            if (entry.callable) |earlier| {
                if (!lexical.sameIdentity(earlier.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported name '{s}'", .{alias});
                if (!sameMixfixParts(earlier.mixfix, exposed.mixfix)) return self.fail(unit, span, "conflicting imported mixfix forms for '{s}'", .{alias});
                entry.callable_since = @min(entry.callable_since, span.end);
            } else {
                entry.callable = member;
                entry.callable_since = span.end;
            }
            if (exposed.identity.kind == .record) {
                if (entry.type_symbol) |earlier| {
                    if (!lexical.sameIdentity(earlier.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported type '{s}'", .{alias});
                    entry.type_since = @min(entry.type_since, span.end);
                } else {
                    entry.type_symbol = member;
                    entry.type_since = span.end;
                }
            }
        },
        .precedence => {
            if (entry.precedence) |earlier| {
                if (!lexical.sameIdentity(earlier.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported name '{s}'", .{alias});
                entry.precedence_since = @min(entry.precedence_since, span.end);
            } else {
                entry.precedence = member;
                entry.precedence_since = span.end;
            }
        },
        .value, .unknown => {
            try self.checkOrdinary(unit, id, alias, span);
            if (entry.value) |earlier| {
                if (earlier != .member or !lexical.sameIdentity(earlier.member.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported name '{s}'", .{alias});
                entry.value_since = @min(entry.value_since, span.end);
            } else {
                entry.value = .{ .member = member };
                entry.value_since = span.end;
            }
        },
    }
    for (exposed.mixfix) |form| if (form) |value| try self.bindOperator(unit, id, .{ .name = alias, .form = value, .since = span.end }, span);
}

fn bindOperator(self: *ModuleGraph, unit: *Unit, scope: Parser.ScopeId, binding: lexical.Operator, span: source.Span) !void {
    const spelling = binding.form.head;
    const entry = try self.symbol(unit, scope, spelling);
    const role = &entry.operators[@intFromBool(binding.form.leading)];
    if (role.*) |earlier| {
        if (earlier.form == binding.form) {
            if (binding.since < earlier.since) role.* = binding;
            return;
        }
        if (earlier.qualified != null or binding.qualified != null or !std.mem.eql(u8, earlier.name, binding.name))
            return self.fail(unit, span, "conflicting mixfix operator '{s}'", .{spelling});
        if (binding.since >= earlier.since) return;
    }
    role.* = binding;
}
fn collectPublicExports(self: *ModuleGraph, unit: *Unit) !void {
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
            for (declaration.names) |name| try self.publicExport(unit, name.name, name.span, null, &functions, &groups);
        },
        .function => |function| if (function.exported) {
            try self.publicExport(unit, function.name, statement.span, .function, &functions, &groups);
        },
        .expand_block => |block| if (block.exported) {
            try self.publicExport(unit, block.name, statement.span, .block, &functions, &groups);
        },
        .structure => |structure| if (structure.exported) {
            try self.publicExport(unit, structure.name, statement.span, .record, &functions, &groups);
        },
        else => {},
    };
}
fn publicExport(self: *ModuleGraph, unit: *Unit, name: []const u8, span: source.Span, explicit_kind: ?lexical.Kind, functions: *const std.StringHashMapUnmanaged(void), groups: *const std.StringHashMapUnmanaged(void)) !void {
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
const MixfixContext = struct {
    graph: *ModuleGraph,
    unit: *Unit,

    fn block(ptr: *anyopaque, name: ast.OperatorName) ?Parser.BlockLookup.Definition {
        const context: *MixfixContext = @ptrCast(@alignCast(ptr));
        const unit = context.unit;
        const scope = unit.scopeAt(name.span.start);
        const identity = if (name.namespace) |namespace| resolved: {
            const owner = context.graph.resolveNamespaceAt(unit, scope, namespace, name.span.start) orelse return null;
            const symbol_ = context.graph.units.items[owner].public_names.get(name.name) orelse return null;
            break :resolved symbol_.identity;
        } else resolved: {
            const callable = unit.resolverAt(name.span.start).callable(scope, name.name);
            if (callable.shadowed) return null;
            break :resolved (callable.member orelse return null).identity;
        };
        if (identity.kind != .block) return null;
        const owner = context.graph.units.items[identity.module];
        for (owner.headers.expansions) |header| if (std.mem.eql(u8, header.statement.value.expand_block.name, identity.name))
            return .{ .statement = header.statement, .module = identity.module };
        return null;
    }

    fn enterBlock(ptr: *anyopaque, definition: Parser.BlockLookup.Definition, scope: Parser.ScopeId) !void {
        const context: *MixfixContext = @ptrCast(@alignCast(ptr));
        const owner = context.graph.units.items[definition.module];
        var source_scope: ?Parser.ScopeId = null;
        for (owner.headers.expansions) |header| if (header.statement == definition.statement) {
            source_scope = header.scope;
            break;
        };
        const origin = source_scope orelse return;
        const insertion = owner.headers.scopes[origin].insertion orelse return;
        var scopes: std.ArrayList(Parser.ScopeId) = .empty;
        var current: ?Parser.ScopeId = owner.scopeAt(insertion);
        while (current) |id| : (current = owner.headers.scopes[id].parent) {
            try scopes.append(context.graph.syntax, id);
            if (id == origin) break;
        }
        var injected: lexical.Symbols = .{};
        var remaining = scopes.items.len;
        while (remaining != 0) {
            remaining -= 1;
            const id = scopes.items[remaining];
            for (owner.headers.scopes[id].ordinary_names) |name| {
                const symbol_ = try context.graph.syntax.create(lexical.Symbol);
                symbol_.* = .{ .local = .{ .span = name.span, .module = owner.index } };
                try injected.put(context.graph.syntax, name.name, symbol_);
            }
            var symbols = owner.scopes[id].iterator();
            while (symbols.next()) |entry| {
                var symbol_ = owner.resolverAt(insertion).symbolAt(id, entry.key_ptr.*) orelse continue;
                if (injected.get(entry.key_ptr.*)) |earlier| {
                    if (symbol_.local == null and symbol_.value == null and symbol_.callable == null) symbol_.local = earlier.local;
                }
                for (&symbol_.mixfix) |*form| if (form.*) |value| {
                    const copy = try context.graph.syntax.create(ast.MixfixForm);
                    copy.* = value.*;
                    if (copy.group.module == null) copy.group.module = owner.index;
                    form.* = copy;
                };
                for (&symbol_.operators) |*binding| if (binding.*) |*value| {
                    value.since = 0;
                };
                symbol_.value_since = 0;
                symbol_.callable_since = 0;
                symbol_.type_since = 0;
                symbol_.precedence_since = 0;
                const value = try context.graph.syntax.create(lexical.Symbol);
                value.* = symbol_;
                try injected.put(context.graph.syntax, entry.key_ptr.*, value);
            }
        }
        var bindings = injected.iterator();
        while (bindings.next()) |entry| {
            const span = context.unit.headers.scopes[scope].body;
            const destination = try context.graph.symbol(context.unit, scope, entry.key_ptr.*);
            var incoming = entry.value_ptr.*.*;
            if (incoming.hasName()) {
                try context.graph.checkOrdinary(context.unit, scope, entry.key_ptr.*, span);
                if (destination.hasName())
                    return context.graph.fail(context.unit, span, "duplicate block binding '{s}'", .{entry.key_ptr.*});
            }
            inline for (.{ "mixfix", "operators" }) |field| for (&@field(incoming, field), @field(destination.*, field)) |*binding, local| {
                if (local != null and binding.* != null)
                    return context.graph.fail(context.unit, span, "duplicate mixfix binding '{s}'", .{entry.key_ptr.*});
                if (binding.* == null) binding.* = local;
            };
            if (incoming.hasName()) destination.* = incoming else {
                destination.mixfix = incoming.mixfix;
                destination.operators = incoming.operators;
            }
        }
    }

    fn lookup(opaque_context: *anyopaque, name: ast.OperatorName, leading: bool) ?Parser.MixfixLookup.Binding {
        const context: *MixfixContext = @ptrCast(@alignCast(opaque_context));
        const id = context.unit.scopeAt(name.span.start);
        const resolver_ = context.unit.resolverAt(name.span.start);
        const index = @intFromBool(leading);
        if (name.namespace) |alias| {
            if (context.graph.resolveNamespaceAt(context.unit, id, alias, name.span.start)) |module| {
                return context.graph.units.items[module].publicTemplate(name.name, index);
            }
            if (resolver_.readable(id, alias) != null) return null;
        } else {
            if (resolver_.operator(id, name.name, leading)) |binding| {
                if (binding.qualified) |qualified| return .{ .form = binding.form.*, .target = binding.name, .qualified = qualified };
                const call = resolver_.callable(id, binding.name);
                const form = call.mixfix[index] orelse (if (call.member) |member| member.mixfix[index] else null) orelse return null;
                if (std.mem.eql(u8, form.head, name.name)) return .{ .form = form.*, .target = binding.name };
            }
        }
        const options = context.graph.options;
        if (options.mixfix) |fallback| return fallback.lookup(name, leading);
        return null;
    }
};
fn fail(self: *ModuleGraph, unit: *const Unit, span: source.Span, comptime format: []const u8, args: anytype) error{LanguageError} {
    self.diagnostic.* = source.Diagnostic.init(span, format, args);
    self.diagnostic.*.?.setSource(unit.name, unit.source_text);
    return error.LanguageError;
}

fn sameMixfixParts(left: [2]?*const ast.MixfixForm, right: [2]?*const ast.MixfixForm) bool {
    for (left, right) |one, two| {
        if (one == null or two == null) {
            if (one != null or two != null) return false;
            continue;
        }
        if (one.?.parts.len != two.?.parts.len) return false;
        if (!std.mem.eql(u8, one.?.head, two.?.head)) return false;
        for (one.?.parts, two.?.parts) |a, b| {
            if (a == null or b == null) {
                if (a != null or b != null) return false;
            } else if (!std.mem.eql(u8, a.?, b.?)) return false;
        }
    }
    return true;
}

test "a global export does not disclose a same-named private prefix function" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
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

test "lexical function imports replace prefix roles and imported data shadows calls" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "prefix")) return .{ .name = "prefix.huak", .source = "mixfix(wrap) wrap _ in unary;export fn wrap(x:int)->int return x end" };
            if (std.mem.eql(u8, path, "ordinary")) return .{ .name = "ordinary.huak", .source = "export fn wrap(a:int,b:int)->int return a+b end" };
            return .{ .name = "data.huak", .source = "export wrap:=7" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "prefix".wrap as act
        \\if true then
        \\    import "ordinary".wrap as act
        \\    inside:=act (2,3)
        \\end
        \\if true then
        \\    import "data".wrap as act
        \\    mixed:=act
        \\end
        \\outside:=wrap 5
    );
    const script = graph.units.items[0].script;
    const ordinary = script.statements[1].value.conditional.branches[0].body[1].value.assignment.value;
    try std.testing.expect(ordinary.value == .call);
    try std.testing.expectEqual(@as(usize, 2), ordinary.value.call.args.len);
    const mixed = script.statements[2].value.conditional.branches[0].body[1].value.assignment.value;
    try std.testing.expect(mixed.value == .name);
    const unit = graph.units.items[0];
    try std.testing.expect(unit.resolverAt(mixed.span.start).callable(unit.scopeAt(mixed.span.start), "act").shadowed);
    try std.testing.expect(script.statements[3].value.assignment.value.value == .mixfix_call);
}

test "whole function data bindings shadow outer namespaces during prefix parsing" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "library.huak", .source = "mixfix(wrap) wrap _ in unary;export fn wrap(x:int)->int return x end" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "library" as lib
        \\fn parameter(lib:any)->any return lib.wrap+1 end
        \\fn local()->any
        \\    before:=lib.wrap+1
        \\    lib:=7
        \\    return before
        \\end
    );
    const script = graph.units.items[0].script;
    const parameter = script.statements[1].value.function.body[0].value.return_value.?;
    const local = script.statements[2].value.function.body[0].value.assignment.value;
    for ([_]*ast.Expr{ parameter, local }) |expression| {
        try std.testing.expect(expression.value == .binary);
        try std.testing.expect(expression.value.binary.left.value == .member);
    }
}

test "same function imported with different prefix roles is rejected in either order" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "base")) return .{ .name = "base.huak", .source = "export fn f(x:int)->int return x end" };
            return .{ .name = "bridge.huak", .source = "import \"base\".f;mixfix(f) f _ in unary;export f" };
        }
    };
    for ([_][]const u8{ "import \"base\".f;import \"bridge\".f", "import \"bridge\".f;import \"base\".f" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var context: u8 = 0;
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "conflicting imported mixfix forms") != null);
    }
}

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
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
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
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
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
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "conflicting imported name") != null);
}

test "record import type and callable channels follow lexical shadowing" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
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
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
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
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "native domain modules export only their signatures and retain aliases" {
    for (std.enums.values(Namespace)) |namespace| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(memory, memory, .{}, null, &diagnostic);
        const input = try std.fmt.allocPrint(memory, "import {s}\nimport {s} as native\nimport {s}.*\n", .{ namespace.name(), namespace.name(), namespace.name() });
        try graph.root("root.huak", input);
        const root_source = graph.units.items[0];
        const native = graph.units.items[root_source.resolver().namespace(0, "native").?];
        try std.testing.expectEqual(@as(usize, 2), graph.units.items.len);
        try std.testing.expect(root_source.native_namespace == null);
        try std.testing.expectEqual(namespace, native.native_namespace.?);
        try std.testing.expectEqualStrings(namespace.moduleName(), native.name);
        try std.testing.expectEqual(@as(usize, 0), native.imports.items.len);
        try std.testing.expectEqual(root_source.resolver().namespace(0, namespace.name()).?, root_source.resolver().namespace(0, "native").?);
        var count = builtins.constantNames(namespace).len;
        for (builtins.signatures) |signature| {
            if (signature.namespace != namespace) {
                try std.testing.expectEqual(builtins.namespaceLookup(namespace, signature.name) != null, native.public_names.contains(signature.name));
                continue;
            }
            count += 1;
            const exported = native.public_names.get(signature.name).?;
            try std.testing.expectEqual(lexical.Kind.builtin, exported.identity.kind);
            try std.testing.expectEqualStrings(@tagName(signature.id), exported.identity.name);
            try std.testing.expect(lexical.sameIdentity(exported.identity, root_source.resolver().symbolAt(0, signature.name).?.callable.?.identity));
        }
        try std.testing.expectEqual(count, native.public_names.count());
    }
}

test "native selected aliases and reexports preserve the original identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("root.huak", "import math.sin as sine\nimport geometry.circle as disk\nimport pen.pencircle as nib\nexport sine,disk,nib");
    const root_source = graph.units.items[0];
    for ([_]struct { alias: []const u8, original: []const u8 }{
        .{ .alias = "sine", .original = "sin" },
        .{ .alias = "disk", .original = "circle" },
        .{ .alias = "nib", .original = "pencircle" },
    }) |pair| {
        const symbol_value = root_source.public_names.get(pair.alias).?;
        try std.testing.expectEqual(lexical.Kind.builtin, symbol_value.identity.kind);
        try std.testing.expectEqualStrings(pair.original, symbol_value.identity.name);
    }
}

test "native mathematical constants retain data identity and exact values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("root.huak", "import math\nimport math.PI as pi\nexport pi");
    const root_source = graph.units.items[0];
    const native = graph.units.items[root_source.resolver().namespace(0, "math").?];
    for (native.script.statements) |statement| {
        const exported = statement.value.exported;
        if (exported.value) |value| {
            const original = builtins.namespaceConstant(.math, exported.names[0].name).?;
            try std.testing.expectEqual(original.number, value.value.float);
            try std.testing.expectEqual(lexical.Kind.value, native.public_names.get(exported.names[0].name).?.identity.kind);
        }
    }
    try std.testing.expect(lexical.sameIdentity(native.public_names.get("PI").?.identity, root_source.public_names.get("pi").?.identity));
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

test "external resolvers cannot forge a native domain identity before or after its import" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = Namespace.math.moduleName(), .source = "export sneaky:=1" };
        }
    };
    for ([_][]const u8{ "import math\nimport \"spoof\" as external", "import \"spoof\" as external" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var context: u8 = 0;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "reserved native module identity") != null);
    }
}

test "native domains reject members belonging to other responsibilities" {
    for ([_][]const u8{ "import math.print", "import math.picture", "import geometry.pen", "import color.sin", "import animation.draw", "import solver.sin", "import \"std/math.huak\" as obsolete" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
    }
    try std.testing.expect(Namespace.parse("builtin") == null);
}

test "default native namespace syntax does not create an import dependency" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("default.huak", "angle:=math.sin(math.PI/2)\nink:=color.rgb(0,0,0)\ncurve:=geometry.circle((0,0),1)");
    try std.testing.expectEqual(@as(usize, 1), graph.units.items.len);
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

test "imports become visible after declarations and preserve earlier outer bindings" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "outer")) return .{ .name = "outer.huak", .source = "mixfix(wrap) wrap _ in unary;export fn wrap(x:int)->int;return x;end" };
            if (std.mem.eql(u8, path, "inner")) return .{ .name = "inner.huak", .source = "export fn wrap(x:int,y:int)->int;return x+y;end" };
            return .{ .name = "data.huak", .source = "export wrap:=7" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "outer".wrap as act
        \\if true then
        \\    before:=wrap 1
        \\    import "inner".wrap as act
        \\    after:=act(2,3)
        \\end
        \\if true then
        \\    before:=wrap 4
        \\    import "data".wrap as act
        \\    after:=act
        \\end
    );
    const unit = graph.units.items[0];
    try std.testing.expect(unit.resolverAt(0).callable(0, "act").member == null);
    const outer = unit.resolverAt(unit.imports.items[0].span.end).callable(0, "act").member.?.identity;
    for (unit.script.statements[1..]) |conditional| {
        const body = conditional.value.conditional.branches[0].body;
        const before = body[0].value.assignment.value;
        const after = body[2].value.assignment.value;
        const id = unit.scopeAt(before.span.start);
        try std.testing.expect(before.value == .mixfix_call);
        try std.testing.expect(lexical.sameIdentity(outer, unit.resolverAt(before.span.start).callable(id, "act").member.?.identity));
        const selected = unit.resolverAt(after.span.start).callable(id, "act");
        if (after.value == .call) {
            try std.testing.expect(!selected.shadowed);
            try std.testing.expect(!lexical.sameIdentity(outer, selected.member.?.identity));
        } else {
            try std.testing.expect(after.value == .name);
            try std.testing.expect(selected.shadowed);
            try std.testing.expect(selected.member == null);
        }
    }
    var rejected = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try std.testing.expectError(error.LanguageError, rejected.root("early.huak", "value:=act 2;import \"outer\".wrap as act"));
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

test "symbol storage survives map growth and rolls back failed allocation" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    const memory = failing.allocator();
    var tables = [_]lexical.Symbols{.{}};
    defer {
        var values = tables[0].valueIterator();
        while (values.next()) |stored| memory.destroy(stored.*);
        tables[0].deinit(memory);
    }
    var unit: Unit = .{
        .index = 0,
        .name = "symbols.huak",
        .source_text = "",
        .script = .{ .statements = &.{} },
        .headers = .{ .scopes = &.{}, .imports = &.{}, .operators = &.{} },
        .scopes = &tables,
    };
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(memory, memory, .{}, null, &diagnostic);
    try t.expectError(error.OutOfMemory, graph.symbol(&unit, 0, "first"));
    try t.expectEqual(@as(u32, 0), tables[0].count());

    // The table allocation succeeds, but allocating the new symbol fails.
    failing.fail_index = 1;
    try t.expectError(error.OutOfMemory, graph.symbol(&unit, 0, "first"));
    try t.expect(tables[0].capacity() != 0);
    try t.expectEqual(@as(u32, 0), tables[0].count());
    try t.expect(tables[0].get("first") == null);

    failing.fail_index = std.math.maxInt(usize);
    const first = try graph.symbol(&unit, 0, "first");
    first.value = .{ .namespace = 7 };
    const initial_capacity = tables[0].capacity();
    var names: [32][16]u8 = undefined;
    for (&names, 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "symbol-{d}", .{index});
        _ = try graph.symbol(&unit, 0, name);
    }
    try t.expect(tables[0].capacity() > initial_capacity);
    try t.expect(first == try graph.symbol(&unit, 0, "first"));
    try t.expectEqual(@as(u32, 7), first.value.?.namespace);
}

test "namespace paths and exports release every partial allocation" {
    try namespaceAllocationCase(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), namespaceAllocationCase, .{});
}

test "standard namespaces retain canonical native constructor call forms" {
    for ([_]bool{ false, true }) |reversed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        const imports = if (reversed) "import paint.*;import std.*\n" else "import std.*;import paint.*\n";
        const input = try std.fmt.allocPrint(arena.allocator(), "{s}image:=picture with width 10mm height 20mm\nink:=pen with color color.rgb(0,0,0) width 1mm", .{imports});
        try graph.root("constructors.huak", input);
        const unit = graph.units.items[0];
        try std.testing.expect(unit.script.statements[2].value.assignment.value.value == .mixfix_call);
        try std.testing.expect(unit.script.statements[3].value.assignment.value.value == .mixfix_call);
        try std.testing.expect(unit.resolver().callable(0, "picture").member != null);
        try std.testing.expect(unit.resolver().callable(0, "pen").member != null);
        try std.testing.expect(unit.resolver().namespace(0, "picture") != null);
        try std.testing.expect(unit.resolver().namespace(0, "pen") != null);
    }
    for ([_][]const u8{
        "import math as picture;import picture.picture",
        "import picture.picture;import math as picture",
        "import picture as pic;import picture.picture as pic",
    }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("conflict.huak", input));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "conflicts with callable") != null);
    }
}

test "public export identities use bindings visible at the export declaration" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "library.huak", .source = "export fn f()->int;return 2;end" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    const resolver_: ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
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

test "nested imports preserve binding initializer provenance through canonical duplicates" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "leaf")) return .{ .name = "leaf.huak", .source = "export values:=[1];export fn f()->int;return 7;end" };
            if (std.mem.eql(u8, path, "first") or std.mem.eql(u8, path, "second")) return .{ .name = if (std.mem.eql(u8, path, "first")) "first.huak" else "second.huak", .source =
            \\import "leaf" as leaf
            \\export leaf
            };
            return error.MissingModule;
        }
    };
    for ([_]bool{ false, true }) |reversed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var context: u8 = 0;
        var diagnostic: ?source.Diagnostic = null;
        const first = if (reversed) "second" else "first";
        const second = if (reversed) "first" else "second";
        const input = try std.fmt.allocPrint(arena.allocator(),
            \\import "leaf" as ready
            \\import "{s}".leaf as tools
            \\import "{s}".leaf as tools
            \\import "{s}".leaf.{{f,values}}
            \\import "{s}".leaf.{{f,values}}
        , .{ first, second, first, second });
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try graph.root("root.huak", input);
        const unit = graph.units.items[0];
        const resolver_ = unit.resolver();
        const target = graph.names.get("leaf.huak").?;
        const initializer = graph.names.get(if (reversed) "second.huak" else "first.huak").?;
        try std.testing.expectEqual(target, resolver_.namespace(0, "tools").?);
        try std.testing.expectEqual(initializer, resolver_.namespaceInitializer(0, "tools").?);
        try std.testing.expectEqual(initializer, resolver_.callable(0, "f").member.?.initializer);
        try std.testing.expectEqual(initializer, resolver_.readable(0, "values").?.imported.member.initializer);
        try std.testing.expect(unit.resolverAt(0).namespaceInitializer(0, "tools") == null);
        try std.testing.expectEqual(target, unit.imports.items[3].target);
        try std.testing.expectEqual(initializer, unit.imports.items[3].initializer);
    }
}
