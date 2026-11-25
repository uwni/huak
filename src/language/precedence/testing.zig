//! The resolver and expression parser shared by the precedence tests.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Allocator = std.mem.Allocator;
const precedence = @import("../precedence.zig");
const Id = precedence.Id;

pub const TestResolver = struct {
    id: Id,
    pub fn operatorGroup(self: *TestResolver, _: anytype) !Id {
        return self.id;
    }
};

pub fn testExpression(allocator: Allocator, text: []const u8) !*ast.Expr {
    var diagnostic: ?source.Diagnostic = null;
    var parser = try @import("../Parser.zig").init(allocator, text, .{}, &diagnostic);
    const script = try parser.parse();
    return script.statements[script.statements.len - 1].value.assignment.value;
}
