//! Names across modules: imports, module and native namespaces, and exports.
const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Span = source.Span;
const ModuleGraph = @import("../ModuleGraph.zig");
const groups = @import("groups.zig");
const Compiler = @import("Compiler.zig");
const expressions = @import("expressions.zig");
const Context = @import("Context.zig");
const ungroup = ast.ungroup;
const namedConstant = expressions.namedConstant;

pub const CallableTarget = struct { target: CallTarget, module: ?u32 = null, initializer: ?u32 = null };

pub const CallTarget = @FieldType(bc.Export, "target");

pub fn imported(self: *const Compiler, alias: []const u8, span: Span) ?u32 {
    return self.build.graph.resolveNamespaceAt(self.environment.unit, self.environment.unit.scopeAt(span.start), alias, span.start);
}

pub fn moduleExpression(self: *const Compiler, expression: *ast.Expr) ?u32 {
    const inner = ungroup(expression);
    return switch (inner.value) {
        .name => |name| imported(self, name, inner.span),
        .member => |member| if (moduleExpression(self, member.object)) |owner|
            self.build.graph.exportedNamespace(owner, member.name)
        else
            null,
        else => null,
    };
}

pub fn moduleInitializer(self: *const Compiler, expression: *ast.Expr) ?u32 {
    const inner = ungroup(expression);
    return switch (inner.value) {
        .name => |name| self.environment.unit.resolverAt(inner.span.start).namespaceInitializer(self.environment.unit.scopeAt(inner.span.start), name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len]),
        .member => |member| moduleInitializer(self, member.object),
        else => null,
    };
}

pub fn defaultNamespace(self: *const Compiler, context: *Context, name: []const u8, span: Span) ?builtin.Namespace {
    const native = builtin.Namespace.parse(name) orelse return null;
    return if (self.environment.unit.resolverAt(span.start).readable(self.environment.unit.scopeAt(span.start), name) == null and context.resolve(name, span) == null) native else null;
}

pub fn prelude(self: *const Compiler, name: []const u8) ?builtin.Signature {
    if (self.environment.unit.native_namespace) |native| return builtin.namespaceLookup(native, name);
    return builtin.implicit(name);
}

pub fn callTarget(self: *const Compiler, name: []const u8, member_: ?*const ModuleGraph.lexical.Member) ?CallTarget {
    if (member_) |member| {
        if (member.module != self.environment.module_index) return memberExport(self, member.*).target;
        return if (self.environment.records.get(member.name)) |index| .{ .record = index } else null;
    }
    if (self.environment.functions.get(name)) |index| return .{ .function = index };
    return if (prelude(self, name)) |signature| .{ .builtin = signature.id } else null;
}

pub fn namespaceCallTarget(self: *const Compiler, owner: u32, name: []const u8) ?CallTarget {
    const native = self.build.graph.units.items[owner].native_namespace orelse return null;
    const signature = builtin.namespaceConstructor(native, name) orelse return null;
    return .{ .builtin = signature.id };
}

pub fn memberExport(self: *const Compiler, member: ModuleGraph.lexical.Member) bc.Export {
    for (self.build.modules[member.module].exports) |exposed| if (std.mem.eql(u8, member.name, exposed.name)) return exposed;
    unreachable;
}

pub fn importInitializer(self: *const Compiler, span: Span) ?u32 {
    const unit = self.environment.unit;
    for (unit.imports.items, 0..) |item, i| {
        if (item.span.start != span.start) continue;
        // Leading top-level imports have run before any subsequent block or function can execute.
        const leading = @min(i, unit.script.statements.len);
        for (unit.imports.items[0..leading], unit.script.statements[0..leading]) |prior, statement| {
            if (statement.value != .imported or statement.span.start != prior.span.start) break;
            if (prior.initializer == item.initializer) return null;
        }
        return item.initializer;
    }
    unreachable;
}

pub fn collectImportedSymbols(self: *Compiler) !void {
    for (self.environment.unit.imports.items) |item| switch (item.form) {
        .namespace => |name| {
            if (namedConstant(name) != null)
                return self.fail(item.span, "import namespace '{s}' conflicts with a builtin", .{name});
        },
        .all => for (self.build.modules[item.target].exports) |exposed| {
            try checkImportedFunction(self, item.scope, exposed.name, exposed, item.span);
        },
        .selected => |selected| for (selected) |binding| {
            const exposed = try importedExport(self, item.target, binding.name, binding.span);
            try checkImportedFunction(self, item.scope, binding.alias, exposed, binding.span);
        },
    };
}

pub fn checkImportedFunction(self: *Compiler, id: Parser.ScopeId, name: []const u8, exposed: bc.Export, span: Span) !void {
    const callable = exposed.target == .function or exposed.target == .builtin or exposed.target == .record;
    if (callable and namedConstant(name) != null)
        return self.fail(span, "imported function '{s}' conflicts with a builtin", .{name});
    if (callable) {
        const first = memberExport(self, self.environment.unit.scopes[id].get(name).?.callable.?);
        if (!sameMixfix(first.mixfix, exposed.mixfix))
            return self.fail(span, "conflicting imported operator roles for '{s}'", .{name});
    }
}

pub fn importedExport(self: *Compiler, module_index: u32, name: []const u8, span: Span) !bc.Export {
    for (self.build.modules[module_index].exports) |item| if (std.mem.eql(u8, item.name, name)) return item;
    return self.fail(span, "module '{s}' does not export '{s}'", .{ self.build.modules[module_index].name, name });
}

pub fn exportName(self: *Compiler, name: []const u8, span: Span, name_span: Span, explicit_kind: ?ModuleGraph.lexical.Kind) !void {
    if (self.export_names.contains(name)) return self.fail(name_span, "duplicate export '{s}'", .{name});
    const resolver_ = self.environment.unit.resolverAt(name_span.start);
    const call = resolver_.callable(0, name);
    const imported_value: ?bc.Export = if (resolver_.readable(0, name)) |readable| (if (readable == .imported and readable.imported == .member) memberExport(self, readable.imported.member) else null) else null;
    const imported_function: ?bc.Export = if (call.member) |member| (if (member.module != self.environment.module_index) memberExport(self, member.*) else null) else null;
    const target: @FieldType(bc.Export, "target") = if (explicit_kind == .block or (call.member != null and call.member.?.identity.kind == .block))
        .{ .block = if (call.member) |member| member.identity.module else self.environment.module_index }
    else if (explicit_kind == .function)
        .{ .function = self.environment.functions.get(name).? }
    else if (explicit_kind == .record)
        .{ .record = self.environment.records.get(name).? }
    else if (self.environment.globals.get(name)) |binding|
        .{ .global = binding.index }
    else if (imported_value) |exposed|
        exposed.target
    else if (imported(self, name, name_span)) |module_index|
        .{ .namespace = module_index }
    else if (self.environment.functions.get(name)) |function|
        .{ .function = function }
    else if (self.environment.records.get(name)) |record|
        .{ .record = record }
    else if (imported_function) |exposed|
        exposed.target
    else if (self.environment.group_names.get(name)) |group|
        .{ .precedence = group }
    else if (resolver_.precedence(0, name)) |member|
        memberExport(self, member).target
    else if (prelude(self, name)) |signature|
        .{ .builtin = signature.id }
    else
        return self.fail(name_span, "unknown exported variable or function '{s}'", .{name});
    const callable = target == .function or target == .builtin or target == .record;
    var forms: [2]?bc.MixfixForm = .{ null, null };
    if (callable) for (0..2) |index| {
        forms[index] = if (call.mixfix[index]) |form| try copyMixfix(self, form.*) else if (imported_function) |item| item.mixfix[index] else null;
    };
    try self.export_names.put(self.allocator, name, {});
    try self.exports.append(self.allocator, .{ .name = name, .target = target, .span = span, .mixfix = forms });
}

pub fn copyMixfix(self: *Compiler, form: ast.MixfixForm) !bc.MixfixForm {
    const group = try groups.groupNamed(self, form.group);
    const parts = try self.allocator.dupe(?[]const u8, form.parts);
    return .{ .head = form.head, .parts = parts, .group = group };
}

pub fn qualifiedTarget(self: *Compiler, name: ast.OperatorName) !CallableTarget {
    const previous = self.environment;
    self.environment = self.build.environments[name.module.?];
    defer self.environment = previous;
    const namespace = name.namespace.?;
    const unit = self.environment.unit;
    const resolver = unit.resolverAt(name.span.start);
    const scope = unit.scopeAt(name.span.start);
    if (imported(self, namespace, name.span)) |module| {
        const exposed = try importedExport(self, module, name.name, name.span);
        const root = namespace[0 .. std.mem.findScalar(u8, namespace, '.') orelse namespace.len];
        return .{ .target = exposed.target, .module = module, .initializer = resolver.namespaceInitializer(scope, root) };
    }
    if (resolver.readable(scope, namespace) == null) if (builtin.Namespace.parse(namespace)) |native| {
        const signature = builtin.namespaceLookup(native, name.name) orelse return self.fail(name.span, "{s} has no function '{s}'", .{ namespace, name.name });
        return .{ .target = .{ .builtin = signature.id } };
    };
    return self.fail(name.span, "unknown module namespace '{s}'", .{namespace});
}

fn sameMixfix(left: [2]?bc.MixfixForm, right: [2]?bc.MixfixForm) bool {
    for (left, right) |one, two| {
        if (one == null or two == null) {
            if (one != null or two != null) return false;
            continue;
        }
        if (one.?.group != two.?.group or one.?.parts.len != two.?.parts.len) return false;
        if (!std.mem.eql(u8, one.?.head, two.?.head)) return false;
        for (one.?.parts, two.?.parts) |a, b| {
            if (a == null or b == null) {
                if (a != null or b != null) return false;
            } else if (!std.mem.eql(u8, a.?, b.?)) return false;
        }
    }
    return true;
}
