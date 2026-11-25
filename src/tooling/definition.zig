//! Source navigation over the compiler's existing module graph and lexical
//! identities. This walk classifies syntax; name/import lookup stays in scope.zig.
const std = @import("std");
const ast = @import("../language/ast.zig");
const ModuleGraph = @import("../language/ModuleGraph.zig");
const Frontend = @import("Frontend.zig");
const locations = @import("position.zig");
const standard = @import("huak_std");
const builtins = @import("../language/builtin.zig");
const targets = @import("definition/targets.zig");
const under_cursor = @import("definition/cursor.zig");
const Query = @import("definition/Query.zig");
pub const hover = @import("definition/hover.zig");
pub const completion = @import("definition/completion.zig");
const typstUseAt = under_cursor.typstUseAt;
const tokenAt = under_cursor.tokenAt;
const SyntaxAt = under_cursor.SyntaxAt;

pub const Location = struct { path: []const u8, range: locations.Range };
pub const NativeConstant = struct { namespace: builtins.Namespace, name: []const u8 };
const NativeTarget = union(enum) { namespace: builtins.Namespace, function: builtins.Id, constant: NativeConstant };
pub const Target = struct { unit: *const ModuleGraph.Unit, span: ast.Span, native: ?NativeTarget = null, module_start: bool = false };
pub const Role = enum { value, callable, type_symbol, precedence, exported };

/// The result and all temporary graph storage belong to the caller's arena.
/// Invalid syntax has no destination; allocation failures remain visible.
pub fn find(frontend: *const Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) !?Location {
    const target = (try lookup(frontend, arena, text, path, byte_offset)).target orelse return null;
    if (target.native != null) return null;
    return .{ .path = target.unit.name, .range = .{ .start = locations.at(target.unit.source_text, target.span.start), .end = locations.at(target.unit.source_text, target.span.end) } };
}

const Lookup = struct { target: ?Target = null, identifier: ?[]const u8 = null };

pub fn lookup(frontend: *const Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) !Lookup {
    var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
    const parsed: ?ModuleGraph = frontend.graph(arena, text, path, &diagnostic) catch |err| incomplete: {
        if (err == error.OutOfMemory) return err;
        break :incomplete null;
    };
    const blocks = if (parsed) |*graph| graph.units.items[0].headers.source_blocks else null;
    // A `huak.name` read in Typst code names the Huak value it reads, never
    // a builtin function of that name.
    if (parsed) |*graph| if (typstUseAt(graph.units.items[0], byte_offset)) |use| {
        const query: Query = .{ .graph = graph, .unit = graph.units.items[0], .token = .{ .kind = .identifier, .span = use.span }, .name = use.name };
        return .{ .target = query.named(use.name, use.span.start, .value) };
    };
    const token = try tokenAt(frontend, text, byte_offset, blocks) orelse return .{};
    const name = text[token.span.start..token.span.end];
    var result: Lookup = .{ .identifier = if (token.kind == .identifier) name else null };
    if (parsed) |*graph| {
        const unit = graph.units.items[0];
        const query: Query = .{ .graph = graph, .unit = unit, .token = token, .name = name };
        if (SyntaxAt.find(unit.script.statements, token.span).node) |node| result.target = switch (node) {
            .statement => |stmt| targets.statementTarget(query, stmt),
            .expression => |expr| targets.expressionTarget(query, expr),
        };
    }
    return result;
}

/// The URI scheme of the standard library's modules, which a client asks the
/// language server to read.
pub const standard_scheme = "huak-stdlib";

pub fn uriForPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (standard.source(path) != null) return std.fmt.allocPrint(arena, "{s}:/{s}", .{ standard_scheme, path });
    const address: std.Uri = .{ .scheme = "file", .host = .{ .raw = "" }, .path = .{ .raw = path } };
    return std.fmt.allocPrint(arena, "{f}", .{address.fmt(.all)});
}

test {
    _ = @import("definition/cursor.zig");
    _ = @import("definition/navigation_test.zig");
    _ = @import("definition/records_test.zig");
    _ = @import("definition/native_test.zig");
    _ = @import("definition/modules_test.zig");
}
