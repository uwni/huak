//! Record type inference for member navigation and completion.
const std = @import("std");
const ast = @import("../../language/ast.zig");
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const definition = @import("../definition.zig");
const Query = @import("Query.zig");
const under_cursor = @import("cursor.zig");
const ungroup = ast.ungroup;
const SyntaxAt = under_cursor.SyntaxAt;
const Target = definition.Target;

const RecordTarget = struct { unit: *const ModuleGraph.Unit, statement: *const ast.Stmt };

pub fn recordNamed(self: Query, name: []const u8, offset: usize) ?RecordTarget {
    const target = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| blk: {
        const id = self.graph.resolveNamespaceAt(self.unit, self.unit.scopeAt(offset), name[0..dot], offset) orelse return null;
        break :blk self.public(id, name[dot + 1 ..]) orelse return null;
    } else self.named(name, offset, .type_symbol) orelse return null;
    return recordAt(target);
}

/// Navigation follows explicit annotations, aliases and declared function
/// results. Unknown dynamic values deliberately have no fabricated fields.
pub fn recordForExpression(self: Query, expr_: *const ast.Expr, depth: usize) ?RecordTarget {
    if (depth > 32) return null;
    const expr = ungroup(expr_);
    switch (expr.value) {
        .call => {
            const target = self.callTarget(expr) orelse return null;
            if (target.native != null) return null;
            if (recordAt(target)) |record| return record;
            for (target.unit.script.statements) |statement| if (statement.value == .function and
                statement.span.start <= target.span.start and target.span.end <= statement.span.end)
                if (statement.value.function.result) |annotation_| return recordNamed(self.inUnit(target.unit), annotation_.name, annotation_.span.start);
        },
        .name => |name| {
            const target = self.named(name, expr.span.start, .value) orelse return null;
            if (target.native != null) return null;
            return recordForBinding(self.inUnit(target.unit), target.span, depth + 1);
        },
        .member => |member_| {
            const object = ungroup(member_.object);
            if (self.namespaceReceiver(object)) |id| {
                const target = self.public(id, member_.name) orelse return null;
                return recordForBinding(self.inUnit(target.unit), target.span, depth + 1);
            }
            const parent = recordForExpression(self, member_.object, depth + 1) orelse return null;
            for (parent.statement.value.structure.fields) |field| if (std.mem.eql(u8, field.name, member_.name))
                return recordNamed(self.inUnit(parent.unit), field.annotation.name, field.annotation.span.start);
        },
        else => {},
    }
    return null;
}

pub fn recordForBinding(self: Query, span: ast.Span, depth: usize) ?RecordTarget {
    if (SyntaxAt.find(self.unit.script.statements, span).statement) |statement| {
        switch (statement.value) {
            .assignment => |assignment| {
                if (assignment.annotation) |annotation_| return recordNamed(self, annotation_.name, annotation_.span.start);
                return recordForExpression(self, assignment.value, depth + 1);
            },
            .exported => |exported| if (exported.value) |value| return recordForExpression(self, value, depth + 1),
            .parameter => |parameter| {
                if (parameter.annotation) |annotation_| return recordNamed(self, annotation_.name, annotation_.span.start);
                if (parameter.default) |value| return recordForExpression(self, value, depth + 1);
            },
            inline .function, .expand_block => |function| {
                for (function.params) |parameter| if (parameter.span.start <= span.start and span.end <= parameter.span.end)
                    return recordNamed(self, parameter.annotation.name, parameter.annotation.span.start);
            },
            else => {},
        }
    }
    return null;
}

pub fn recordAt(target: Target) ?RecordTarget {
    if (target.native != null) return null;
    for (target.unit.script.statements) |statement| if (statement.value == .structure and
        statement.span.start <= target.span.start and target.span.end <= statement.span.end)
        return .{ .unit = target.unit, .statement = statement };
    return null;
}

pub fn fieldTarget(record: RecordTarget, name: []const u8) ?Target {
    for (record.statement.value.structure.fields) |field| if (std.mem.eql(u8, field.name, name))
        return .{ .unit = record.unit, .span = .{ .start = field.span.start, .end = field.span.start + field.name.len } };
    return null;
}
