//! Hover text, and the symbol summaries completion items reuse as detail.
const std = @import("std");
const ast = @import("../../language/ast.zig");
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const Frontend = @import("../Frontend.zig");
const builtins = @import("../../language/builtin.zig");
const definition = @import("../definition.zig");
const Query = @import("Query.zig");
const under_cursor = @import("cursor.zig");
const lookup = definition.lookup;
const Target = definition.Target;
const NativeConstant = definition.NativeConstant;
const SyntaxAt = under_cursor.SyntaxAt;

pub fn describe(frontend: *const Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) !?[]const u8 {
    const symbol = try lookup(frontend, arena, text, path, byte_offset);
    if (symbol.target) |target| if (try describeTarget(arena, target)) |detail| return detail;
    const name = symbol.identifier orelse return null;
    const signature = builtins.implicit(name) orelse return null;
    return try builtinText(arena, signature);
}

fn describeTarget(arena: std.mem.Allocator, target: Target) !?[]const u8 {
    if (target.native) |native| return switch (native) {
        .namespace => |namespace| try std.fmt.allocPrint(arena, "{s} — native functions and constants", .{namespace.name()}),
        .function => |id| try nativeFunctionText(arena, builtins.signature(id)),
        .constant => |constant| try nativeConstantText(arena, constant),
    };
    if (target.unit.data) |data| return try std.fmt.allocPrint(arena, "{s}: {s}", .{ target.unit.name, data.valueType().name() });
    if (target.module_start) return try std.fmt.allocPrint(arena, "module {s}", .{target.unit.name});
    if (try describeStatements(arena, target.unit.script.statements, target.span)) |detail| return detail;
    if (builtins.lookup(target.unit.source_text[target.span.start..target.span.end])) |signature| return try builtinText(arena, signature);
    return null;
}

pub fn builtinText(arena: std.mem.Allocator, signature: builtins.Signature) ![]u8 {
    return builtinNamedText(arena, signature, signature.name);
}

fn builtinNamedText(arena: std.mem.Allocator, signature: builtins.Signature, name: []const u8) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    errdefer text.deinit();
    try text.writer.print("fn {s}(", .{name});
    for (signature.args, 0..) |argument, index| {
        if (index != 0) try text.writer.writeAll(", ");
        if (index < signature.parameter_names.len) try text.writer.print("{s}: ", .{signature.parameter_names[index]});
        try text.writer.print("{s}{s}", .{ argument.name(), if (index >= signature.minimum) "?" else "" });
    }
    if (signature.variadic) |element| {
        if (signature.args.len != 0) try text.writer.writeAll(", ");
        try text.writer.print("{s}...", .{element.name()});
    }
    try text.writer.print(") -> {s}", .{signature.result.name()});
    return text.toOwnedSlice();
}

pub fn nativeFunctionText(arena: std.mem.Allocator, signature: builtins.Signature) ![]const u8 {
    const name = if (signature.namespace) |namespace|
        try std.fmt.allocPrint(arena, "{s}.{s}", .{ namespace.name(), signature.name })
    else
        signature.name;
    return builtinNamedText(arena, signature, name);
}

pub fn nativeConstantText(arena: std.mem.Allocator, constant: NativeConstant) ![]const u8 {
    const value = builtins.namespaceConstant(constant.namespace, constant.name) orelse return "unknown native constant";
    return switch (value) {
        .number => |number| std.fmt.allocPrint(arena, "{s}.{s}: number = {d}", .{ constant.namespace.name(), constant.name, number }),
        else => std.fmt.allocPrint(arena, "{s}.{s}: {s}", .{ constant.namespace.name(), constant.name, value.valueType().name() }),
    };
}

pub fn symbolDetail(arena: std.mem.Allocator, query: Query, identity: ModuleGraph.lexical.Identity) ![]const u8 {
    if (identity.kind == .namespace)
        return std.fmt.allocPrint(arena, "module {s}", .{query.graph.units.items[identity.module].name});
    if (identity.kind == .builtin) if (builtins.identity(identity.name)) |signature| return nativeFunctionText(arena, signature);
    if (query.targetIdentity(identity)) |target| {
        if (target.native) |native| if (native == .constant) return nativeConstantText(arena, native.constant);
        if (try describeStatements(arena, target.unit.script.statements, target.span)) |detail| return detail;
    }
    return "Huak symbol";
}

fn describeStatements(arena: std.mem.Allocator, body: []const *ast.Stmt, span: ast.Span) anyerror!?[]const u8 {
    if (SyntaxAt.find(body, span).statement) |statement| {
        switch (statement.value) {
            .structure => |structure| {
                for (structure.fields) |field| if (field.span.start == span.start)
                    return try std.fmt.allocPrint(arena, "{s}.{s}: {s}", .{ structure.name, field.name, field.annotation.name });
                var text: std.Io.Writer.Allocating = .init(arena);
                try text.writer.print("struct {s}", .{structure.name});
                for (structure.fields) |field| try text.writer.print("\n    {s}: {s}{s}", .{ field.name, field.annotation.name, if (field.default != null) " = …" else "" });
                try text.writer.writeAll("\nend");
                return try text.toOwnedSlice();
            },
            inline .function, .expand_block => |function| {
                for (function.params) |parameter| if (parameter.span.start == span.start)
                    return try std.fmt.allocPrint(arena, "parameter {s}: {s}", .{ parameter.name, parameter.annotation.name });
                return try functionText(arena, statement);
            },
            .assignment => |assignment| return try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ assignment.name, if (assignment.annotation != null) ": " else "", if (assignment.annotation) |annotation_| annotation_.name else "" }),
            .parameter => |parameter| return try std.fmt.allocPrint(arena, "param {s}{s}{s}", .{ parameter.name, if (parameter.annotation != null) ": " else "", if (parameter.annotation) |annotation_| annotation_.name else "" }),
            else => {},
        }
    }
    return null;
}

pub fn functionText(arena: std.mem.Allocator, statement: *const ast.Stmt) ![]const u8 {
    const function = switch (statement.value) {
        inline .function, .expand_block => |value| .{ .name = value.name, .params = value.params, .result = value.result },
        else => unreachable,
    };
    var text: std.Io.Writer.Allocating = .init(arena);
    try text.writer.print("{s} {s}(", .{ if (statement.value == .expand_block) "expand_block" else "fn", function.name });
    for (function.params, 0..) |parameter, index| {
        if (index != 0) try text.writer.writeAll(", ");
        try text.writer.print("{s}: {s}{s}{s}", .{ parameter.name, parameter.annotation.name, if (parameter.variadic) "..." else "", if (parameter.default != null) " = …" else "" });
    }
    try text.writer.print(") -> {s}", .{if (function.result) |annotation_| annotation_.name else "unit"});
    return text.toOwnedSlice();
}
