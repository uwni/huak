//! End labels derived from the ordinary syntax tree. Typst expressions remain
//! opaque, so their text cannot introduce Huak blocks or matching end tokens.
const std = @import("std");
const ast = @import("../language/ast.zig");
const locations = @import("position.zig");

pub const Location = struct { uri: []const u8, range: locations.Range };
pub const LabelPart = struct { value: []const u8, location: Location };
pub const Hint = struct {
    position: locations.Position,
    label: []const LabelPart,
    paddingLeft: bool = true,
};

/// Returned labels, parts and hints belong to the request arena. The range is
/// in UTF-8 byte offsets after the LSP layer has validated UTF-16 coordinates.
pub fn collect(arena: std.mem.Allocator, input: []const u8, statements: []const *ast.Stmt, uri: []const u8, range: ast.Span) ![]const Hint {
    var collector: Collector = .{ .arena = arena, .input = input, .uri = uri, .range = range };
    try ast.walkStatements(&collector, statements);
    return collector.hints.toOwnedSlice(arena);
}

const Collector = struct {
    arena: std.mem.Allocator,
    input: []const u8,
    uri: []const u8,
    range: ast.Span,
    hints: std.ArrayList(Hint) = .empty,
    starts: Cursor = .{},
    ends: Cursor = .{},

    pub fn enter(self: *Collector, node: ast.Node) anyerror!bool {
        const span = switch (node) {
            .statement => |value| value.span,
            .expression => |value| value.span,
        };
        const start = self.starts.at(self.input, span.start);
        try ast.walkChildren(self, node);
        const label: []const u8 = switch (node) {
            .statement => |statement| switch (statement.value) {
                .function => |value| try std.fmt.allocPrint(self.arena, "fn {s}", .{value.name}),
                .expand_block => |value| try std.fmt.allocPrint(self.arena, "expand_block {s}", .{value.name}),
                .conditional => "if",
                .for_loop => |value| try std.fmt.allocPrint(self.arena, "for {s}", .{value.name}),
                .while_loop => "while",
                .precedence_group => |value| try std.fmt.allocPrint(self.arena, "precedence {s}", .{value.name}),
                .structure => |value| try std.fmt.allocPrint(self.arena, "struct {s}", .{value.name}),
                else => return false,
            },
            .expression => |expression| switch (expression.value) {
                .block => "block",
                .expansion => |value| if (value.args.len == 1 and value.args[0].value == .name)
                    try std.fmt.allocPrint(self.arena, "{s} {s}", .{ value.name.name, value.args[0].value.name })
                else
                    value.name.name,
                else => return false,
            },
        };
        const end = self.ends.at(self.input, span.end);
        if (start.line == end.line or span.end < self.range.start or span.end > self.range.end) return false;
        const parts = try self.arena.alloc(LabelPart, 1);
        parts[0] = .{ .value = label, .location = .{ .uri = self.uri, .range = .{ .start = start, .end = start } } };
        try self.hints.append(self.arena, .{ .position = end, .label = parts });
        return false;
    }
};

const Cursor = struct {
    byte_offset: usize = 0,
    position: locations.Position = .{ .line = 0, .character = 0 },

    fn at(self: *Cursor, input: []const u8, offset: usize) locations.Position {
        std.debug.assert(offset >= self.byte_offset);
        const relative = locations.at(input[self.byte_offset..], offset - self.byte_offset);
        self.position.line += relative.line;
        self.position.character = if (relative.line == 0) self.position.character + relative.character else relative.character;
        self.byte_offset = offset;
        return self.position;
    }
};
