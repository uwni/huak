//! Completion items: names in scope, native namespace members, module members, and constructor labels not yet supplied.
const std = @import("std");
const ast = @import("../../language/ast.zig");
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const Frontend = @import("../Frontend.zig");
const builtins = @import("../../language/builtin.zig");
const records = @import("records.zig");
const hover = @import("hover.zig");
const Query = @import("Query.zig");
const under_cursor = @import("cursor.zig");
const nativeFunctionText = hover.nativeFunctionText;
const nativeConstantText = hover.nativeConstantText;
const symbolDetail = hover.symbolDetail;
const SyntaxAt = under_cursor.SyntaxAt;
const ungroup = ast.ungroup;
const recordAt = records.recordAt;
const builtinText = hover.builtinText;
const functionText = hover.functionText;

pub const Completion = struct {
    label: []const u8,
    kind: u8,
    detail: []const u8,
    // zlinter-disable-next-line field_naming - LSP JSON field name
    insertText: ?[]const u8 = null,
};

fn appendCompletion(arena: std.mem.Allocator, items: *std.ArrayList(Completion), item: Completion) !void {
    for (items.items) |previous| if (std.mem.eql(u8, previous.label, item.label)) return;
    try items.append(arena, item);
}

fn appendNativeCompletions(arena: std.mem.Allocator, items: *std.ArrayList(Completion), namespace: builtins.Namespace) !void {
    for (builtins.signatures) |signature| if (signature.namespace == namespace)
        try appendCompletion(arena, items, .{ .label = signature.name, .kind = 3, .detail = try nativeFunctionText(arena, signature) });
    for (builtins.constantNames(namespace)) |name|
        try appendCompletion(arena, items, .{ .label = name, .kind = 21, .detail = try nativeConstantText(arena, .{ .namespace = namespace, .name = name }) });
}

fn completionKind(kind: ModuleGraph.lexical.Kind) u8 {
    return switch (kind) {
        .namespace => 9,
        .record => 22,
        .function, .builtin => 3,
        else => 6,
    };
}

fn appendModuleCompletions(arena: std.mem.Allocator, items: *std.ArrayList(Completion), query: Query, id: u32) !void {
    var exports = query.graph.units.items[id].public_names.iterator();
    while (exports.next()) |entry| {
        const exposed = entry.value_ptr.*;
        try appendCompletion(arena, items, .{ .label = entry.key_ptr.*, .kind = completionKind(exposed.identity.kind), .detail = try symbolDetail(arena, query, exposed.identity) });
    }
}

/// Syntax requests do not execute or typecheck a program. Completing an empty
/// member after '.' repairs only that missing identifier in a request snapshot.
pub fn complete(frontend: *const Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) ![]const Completion {
    var input = text;
    if (byte_offset != 0 and text[byte_offset - 1] == '.')
        input = try std.fmt.allocPrint(arena, "{s}__huak_completion__{s}", .{ text[0..byte_offset], text[byte_offset..] });
    var diagnostic: ?@import("../../language/source.zig").Diagnostic = null;
    const graph = frontend.graph(arena, input, path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        return &.{};
    };
    const unit = graph.units.items[0];
    const query: Query = .{ .graph = &graph, .unit = unit, .token = .{ .kind = .identifier, .span = .{ .start = byte_offset, .end = byte_offset } }, .name = "" };
    var items: std.ArrayList(Completion) = .empty;
    const cursor: ast.Span = .{ .start = byte_offset, .end = byte_offset };
    if (SyntaxAt.find(unit.script.statements, cursor).completion) |context| switch (context.value) {
        .member => |member_| {
            const object = ungroup(member_.object);
            if (query.defaultNamespaceReceiver(object)) |namespace| {
                try appendNativeCompletions(arena, &items, namespace);
                return items.toOwnedSlice(arena);
            }
            if (query.namespaceReceiver(object)) |id| {
                try appendModuleCompletions(arena, &items, query, id);
                return items.toOwnedSlice(arena);
            }
            if (records.recordForExpression(query, object, 0)) |record| {
                for (record.statement.value.structure.fields) |field| try appendCompletion(arena, &items, .{ .label = field.name, .kind = 5, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ field.name, field.annotation.name }) });
                return items.toOwnedSlice(arena);
            }
            return items.toOwnedSlice(arena);
        },
        .call => |call| {
            if (call.dot and call.args.len != 0) if (query.defaultNamespaceReceiver(call.args[0])) |namespace| {
                if (std.mem.indexOfScalarPos(u8, input, call.args[0].span.end, '(')) |opening| if (byte_offset <= opening) {
                    try appendNativeCompletions(arena, &items, namespace);
                    return items.toOwnedSlice(arena);
                };
            };
            if (call.dot and call.args.len != 0) if (query.namespaceReceiver(call.args[0])) |id| {
                if (std.mem.indexOfScalarPos(u8, input, call.args[0].span.end, '(')) |opening| if (byte_offset <= opening) {
                    try appendModuleCompletions(arena, &items, query, id);
                    return items.toOwnedSlice(arena);
                };
            };
            const positional = positionalArguments(query, context);
            if (query.callTarget(context)) |target| {
                if (target.native) |native| {
                    if (native == .function) {
                        const signature = builtins.signature(native.function);
                        for (signature.parameter_names, signature.args, 0..) |name, kind, index| if (index >= positional and !argumentSupplied(call.argument_names, name))
                            try appendCompletion(arena, &items, .{ .label = name, .kind = 6, .detail = kind.name(), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{name}) });
                    }
                } else if (recordAt(target)) |record| {
                    for (record.statement.value.structure.fields, 0..) |field, index| if (index >= positional and !argumentSupplied(call.argument_names, field.name))
                        try appendCompletion(arena, &items, .{ .label = field.name, .kind = 5, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ field.name, field.annotation.name }), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{field.name}) });
                } else for (target.unit.script.statements) |statement| if (statement.value == .function and statement.span.start <= target.span.start and target.span.end <= statement.span.end) {
                    for (statement.value.function.params, 0..) |parameter, index| if (index >= positional and !parameter.variadic and !argumentSupplied(call.argument_names, parameter.name))
                        try appendCompletion(arena, &items, .{ .label = parameter.name, .kind = 6, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ parameter.name, parameter.annotation.name }), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{parameter.name}) });
                };
            } else if (builtins.implicit(call.name)) |signature| {
                for (signature.parameter_names, signature.args, 0..) |name, kind, index| if (index >= positional and !argumentSupplied(call.argument_names, name))
                    try appendCompletion(arena, &items, .{ .label = name, .kind = 6, .detail = kind.name(), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{name}) });
            }
            if (items.items.len != 0) return items.toOwnedSlice(arena);
        },
        else => {},
    };
    var scope: ?@import("../../language/Parser.zig").ScopeId = unit.scopeAt(byte_offset);
    while (scope) |id| {
        for (unit.headers.scopes[id].ordinary_names) |binding| try appendCompletion(arena, &items, .{ .label = binding.name, .kind = 6, .detail = "Huak binding" });
        var symbols = unit.scopes[id].iterator();
        while (symbols.next()) |entry| {
            const symbol = unit.resolverAt(byte_offset).symbolAt(id, entry.key_ptr.*) orelse continue;
            const constructor: ?builtins.Signature = if (symbol.value != null and symbol.value.? == .namespace)
                if (graph.units.items[symbol.value.?.namespace].native_namespace) |namespace| builtins.namespaceConstructor(namespace, entry.key_ptr.*) else null
            else
                null;
            const detail = if (constructor) |signature| try builtinText(arena, signature) else if (symbol.type_symbol) |member| try symbolDetail(arena, query, member.identity) else if (symbol.callable) |member| try symbolDetail(arena, query, member.identity) else "Huak symbol";
            try appendCompletion(arena, &items, .{ .label = entry.key_ptr.*, .kind = if (constructor != null) 4 else if (symbol.type_symbol != null) 22 else if (symbol.callable != null) 3 else if (symbol.value != null and symbol.value.? == .namespace) 9 else 6, .detail = detail });
        }
        scope = unit.headers.scopes[id].parent;
    }
    for (unit.script.statements) |statement| switch (statement.value) {
        .structure => |structure| try appendCompletion(arena, &items, .{ .label = structure.name, .kind = 22, .detail = try std.fmt.allocPrint(arena, "struct {s}", .{structure.name}) }),
        inline .function, .expand_block => |function| try appendCompletion(arena, &items, .{ .label = function.name, .kind = 3, .detail = try functionText(arena, statement) }),
        else => {},
    };
    for (std.enums.values(builtins.Namespace)) |namespace| if (query.defaultNamespace(namespace.name(), byte_offset) != null) {
        const constructor = builtins.namespaceConstructor(namespace, namespace.name());
        try appendCompletion(arena, &items, .{ .label = namespace.name(), .kind = if (constructor != null) 4 else 9, .detail = if (constructor) |signature| try builtinText(arena, signature) else "Native namespace" });
    };
    return items.toOwnedSlice(arena);
}

/// Member completion returns only the resolved namespace/object's members.
/// Whitespace around the dot is insignificant to ordinary member syntax.
pub fn memberRequest(input: []const u8, offset: usize) bool {
    var index = @min(offset, input.len);
    while (index != 0 and (std.ascii.isAlphanumeric(input[index - 1]) or input[index - 1] == '_')) index -= 1;
    while (index != 0 and (input[index - 1] == ' ' or input[index - 1] == '\t')) index -= 1;
    return index != 0 and input[index - 1] == '.';
}

fn positionalArguments(query: Query, expression: *const ast.Expr) usize {
    const call = expression.value.call;
    var skip: usize = 0;
    if (call.dot and call.args.len != 0) {
        const object = ungroup(call.args[0]);
        if (query.namespaceReceiver(object) != null or query.defaultNamespaceReceiver(object) != null) skip = 1;
    }
    var count: usize = 0;
    for (skip..call.args.len) |index| {
        if (call.argument_names.len != 0 and call.argument_names[index] != null) break;
        count += 1;
    }
    return count;
}

fn argumentSupplied(names: []const ?[]const u8, name: []const u8) bool {
    for (names) |item| if (item) |label| if (std.mem.eql(u8, label, name)) return true;
    return false;
}
