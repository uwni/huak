//! Loading units through the host resolver: deduplication, limits, reserved native identities, data files and scripts, import resolution, and parsing each script with its unit's lookups.
const std = @import("std");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const DataFormat = @import("../data.zig").Format;
const builtins = @import("../builtin.zig");
const lexical = @import("../scope.zig");
const Namespace = builtins.Namespace;
const ModuleGraph = @import("../ModuleGraph.zig");
const symbols = @import("symbols.zig");
const exports = @import("exports.zig");
const MixfixContext = @import("MixfixContext.zig");

pub fn load(self: *ModuleGraph, resolved: ModuleGraph.ResolvedSource, depth: usize, native: ?Namespace) anyerror!u32 {
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
    const scope_symbols = try self.syntax.alloc(lexical.Symbols, headers.scopes.len);
    @memset(scope_symbols, .{});
    const unit = try self.syntax.create(ModuleGraph.Unit);
    unit.* = .{ .index = index, .name = name, .source_text = text, .script = .{ .statements = &.{} }, .headers = headers, .scopes = scope_symbols, .native_namespace = native };
    try self.units.append(self.syntax, unit);
    try self.names.put(self.syntax, name, index);
    if (format) |data_format| {
        var offset: usize = 0;
        unit.data = data_format.decode(self.allocator, text, &offset) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fail(unit, .{ .start = offset, .end = @min(offset + 1, text.len) }, "invalid {s} data: {s}", .{ @tagName(data_format), @errorName(err) });
        };
    } else try parseScript(self, unit, depth);
    unit.loading = false;
    try self.order.append(self.syntax, index);
    return index;
}

fn parseScript(self: *ModuleGraph, unit: *ModuleGraph.Unit, depth: usize) anyerror!void {
    const headers = unit.headers;
    const name = unit.name;
    const text = unit.source_text;
    const index = unit.index;
    for (headers.records) |header| try symbols.bindRecord(self, unit, header.scope, header.statement);
    for (headers.expansions) |header| {
        const parent = headers.scopes[header.scope].parent orelse 0;
        if (parent != 0) return self.fail(unit, header.statement.span, "expand_block declarations must be at script top level", .{});
        const block_name = header.statement.value.expand_block.name;
        const entry = try symbols.symbol(self, unit, parent, block_name);
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
        const child_source: ModuleGraph.ResolvedSource = if (imported_native) |namespace| native: {
            const canonical = namespace.moduleName();
            const native_source = if (self.names.get(canonical)) |existing| self.units.items[existing].source_text else try nativeSource(self, namespace);
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
                const failure = self.fail(unit, statement.span, "cannot import '{s}': {s}", .{ imported.path, @errorName(err) });
                self.diagnostic.*.?.cause = .{ .module_import = err };
                return failure;
            };
        };
        var target = load(self, child_source, depth + 1, imported_native) catch |err| {
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
                const member: ModuleGraph.PublicSymbol = .{ .identity = .{ .module = target, .name = ModuleGraph.Unit.data_export, .kind = .value } };
                try symbols.bindMember(self, unit, header.scope, alias, target, initializer, ModuleGraph.Unit.data_export, member, statement.span);
            } else try symbols.bindNamespace(self, unit, header.scope, alias, target, initializer, statement.span),
            .all => {
                var exported = self.units.items[target].public_names.iterator();
                while (exported.next()) |entry| try symbols.bindMember(self, unit, header.scope, entry.key_ptr.*, target, initializer, entry.key_ptr.*, entry.value_ptr.*, statement.span);
            },
            .selected => |selected| for (selected) |binding| {
                const exposed = self.units.items[target].public_names.get(binding.name).?;
                try symbols.bindMember(self, unit, header.scope, binding.alias, target, initializer, binding.name, exposed, binding.span);
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
            const entry = try symbols.symbol(self, unit, header.scope, binding.target.name);
            const role = &entry.mixfix[@intFromBool(binding.form.leading)];
            if (role.* != null) return self.fail(unit, header.statement.span, "duplicate mixfix binding '{s}'", .{binding.target.name});
            role.* = &binding.form;
        }
        try symbols.bindOperator(self, unit, header.scope, .{ .name = binding.target.name, .form = &binding.form, .qualified = if (qualified) binding else null }, header.statement.span);
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
    try exports.collectPublicExports(self, unit);
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

test "nested imports preserve binding initializer provenance through canonical duplicates" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
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
