//! Syntax-only nodes. All slices and nodes belong to the parser arena.
const source = @import("source.zig");
const units = @import("../drawing/units.zig");
pub const Span = source.Span;

pub const Unary = enum { negate, positive, logical_not };
pub const Binary = enum { add, subtract, multiply, divide, remainder, power, equal, not_equal, less, less_equal, greater, greater_equal, logical_and, logical_or };
pub const PathJoin = enum { straight, smooth };
pub const PathJoinExpr = struct { left: *Expr, right: *Expr, kind: PathJoin };
pub const OperatorName = struct { namespace: ?[]const u8 = null, name: []const u8, span: Span, module: ?u32 = null };
pub const MixfixBinding = struct { target: OperatorName, form: MixfixForm };
/// The head is the first literal in the template. Null parts are argument slots.
pub const MixfixForm = struct {
    head: []const u8,
    parts: []const ?[]const u8,
    group: OperatorName,
    /// One argument precedes the function word; parts follow that word.
    leading: bool = false,

    pub fn arity(self: MixfixForm) usize {
        var count: usize = @intFromBool(self.leading);
        for (self.parts) |part| if (part == null) {
            count += 1;
        };
        return count;
    }
};
pub const Associativity = enum { left, right, none };
pub const Relation = struct {
    direction: enum { above, below },
    target: OperatorName,
    span: Span,
};
/// The same start[:step]:stop syntax serves loops and list slices. Only a
/// slice may omit stop, in which case its list supplies the final index.
pub const Range = struct { start: *Expr, step: ?*Expr = null, stop: ?*Expr };
pub const Expr = struct {
    span: Span,
    value: union(enum) {
        // Keep the magnitude until semantic analysis so the minimum signed
        // integer can be represented by unary '-' without overflowing first.
        integer: u64,
        float: f64,
        quantity: struct { operand: *Expr, unit: units.Unit },
        boolean: bool,
        string: []const u8,
        name: []const u8,
        list: []const *Expr,
        dict: []const DictEntry,
        vector: struct { x: *Expr, y: *Expr, z: ?*Expr = null },
        unary: struct { op: Unary, operand: *Expr },
        binary: struct { op: Binary, left: *Expr, right: *Expr },
        // Raw joins participate in precedence binding. Bound literals are
        // barriers on later compiler visits, just like lowered word calls.
        path_join: PathJoinExpr,
        path_literal: PathJoinExpr,
        cycle: void,
        // Word operators are deliberately unresolved until every module's
        // declarations are available. Parentheses remain a binding barrier.
        mixfix_call: struct { operator: OperatorName, args: []const *Expr, leading: bool = false, qualified: ?*const MixfixBinding = null },
        grouped: *Expr,
        // Dot calls use the same node: receiver.f(args) becomes f(receiver, args).
        // Names are empty for entirely positional calls, otherwise aligned with
        // args; positional arguments and the receiver have a null name.
        call: struct { name: []const u8, args: []const *Expr, argument_names: []const ?[]const u8 = &.{}, dot: bool = false, mixed: bool = false, qualified: ?*const OperatorName = null },
        index: struct { object: *Expr, index: *Expr },
        slice: struct { object: *Expr, range: Range },
        member: struct { object: *Expr, name: []const u8 },
        /// Original content block, including its brackets, borrowed from module source.
        typst: []const u8,
        block: []const *Stmt,
        expansion: struct { name: OperatorName, definition: *Stmt, module: u32, args: []const *Expr, argument_names: []const ?[]const u8, body: []const *Stmt, scope: u32 },
    },
};
pub const DictEntry = struct { key: []const u8, value: *Expr, span: Span };
pub const Annotation = struct { name: []const u8, span: Span };
pub const Parameter = struct { name: []const u8, annotation: Annotation, span: Span, variadic: bool = false, default: ?*Expr = null };
pub const RecordField = struct { name: []const u8, annotation: Annotation, default: ?*Expr = null, span: Span };
pub const Branch = struct { condition: *Expr, body: []const *Stmt };
pub const ExportName = struct { name: []const u8, span: Span };
pub const ImportBinding = struct { name: []const u8, alias: []const u8, span: Span };
pub const ImportForm = union(enum) {
    namespace: []const u8,
    all,
    selected: []const ImportBinding,
};
pub const Iterable = union(enum) { range: Range, collection: *Expr };
pub const Stmt = struct {
    span: Span,
    value: union(enum) {
        expression: *Expr,
        assignment: struct { name: []const u8, annotation: ?Annotation, value: *Expr, declaration: bool },
        set: struct { target: *Expr, value: *Expr },
        list_append: struct { name: []const u8, value: *Expr },
        append_to: struct { target: *Expr, value: *Expr },
        parameter: struct { name: []const u8, annotation: ?Annotation, default: ?*Expr },
        function: struct { name: []const u8, params: []const Parameter, result: ?Annotation, body: []const *Stmt, exported: bool = false },
        expand_block: struct { name: []const u8, params: []const Parameter, result: ?Annotation, body: []const *Stmt, exported: bool = false },
        insertion,
        structure: struct { name: []const u8, fields: []const RecordField, exported: bool = false },
        conditional: struct { branches: []const Branch, otherwise: []const *Stmt },
        while_loop: struct { condition: *Expr, body: []const *Stmt },
        for_loop: struct { name: []const u8, name_span: Span, iterable: Iterable, body: []const *Stmt },
        break_loop,
        continue_loop,
        return_value: ?*Expr,
        exported: struct { names: []const ExportName, value: ?*Expr },
        default_output: *Expr,
        /// Original code block, including its braces, borrowed from module source.
        setup_typst: []const u8,
        typst_expose: []const ExportName,
        imported: struct { path: []const u8, bare: bool = false, namespace_path: []const []const u8 = &.{}, form: ImportForm },
        precedence_group: struct { name: []const u8, relations: []const Relation, associativity: Associativity = .none },
        mixfix_binding: MixfixBinding,
    },
};

pub const Script = struct { statements: []const *Stmt };

/// Source-order traversal shared by binding collection and editor tools.
/// Returning false from enter skips a subtree (for example a function scope).
pub const Node = union(enum) { statement: *Stmt, expression: *Expr };

pub fn walkStatements(visitor: anytype, statements: []const *Stmt) anyerror!void {
    for (statements) |statement| try walk(visitor, .{ .statement = statement });
}

pub fn walk(visitor: anytype, node: Node) anyerror!void {
    if (!try visitor.enter(node)) return;
    try walkChildren(visitor, node);
}

pub fn walkChildren(visitor: anytype, node: Node) anyerror!void {
    switch (node) {
        .statement => |statement| switch (statement.value) {
            .expression, .default_output => |value| try walk(visitor, .{ .expression = value }),
            inline .assignment, .list_append => |value| try walk(visitor, .{ .expression = value.value }),
            inline .set, .append_to => |value| {
                try walk(visitor, .{ .expression = value.target });
                try walk(visitor, .{ .expression = value.value });
            },
            .parameter => |value| if (value.default) |expr| {
                try walk(visitor, .{ .expression = expr });
            },
            inline .function, .expand_block => |value| {
                for (value.params) |param| if (param.default) |expr| {
                    try walk(visitor, .{ .expression = expr });
                };
                try walkStatements(visitor, value.body);
            },
            .structure => |value| for (value.fields) |field| {
                if (field.default) |expr| try walk(visitor, .{ .expression = expr });
            },
            .conditional => |value| {
                for (value.branches) |branch| {
                    try walk(visitor, .{ .expression = branch.condition });
                    try walkStatements(visitor, branch.body);
                }
                try walkStatements(visitor, value.otherwise);
            },
            .while_loop => |value| {
                try walk(visitor, .{ .expression = value.condition });
                try walkStatements(visitor, value.body);
            },
            .for_loop => |value| {
                switch (value.iterable) {
                    .range => |range| {
                        try walk(visitor, .{ .expression = range.start });
                        if (range.step) |expr| try walk(visitor, .{ .expression = expr });
                        try walk(visitor, .{ .expression = range.stop.? });
                    },
                    .collection => |expr| try walk(visitor, .{ .expression = expr }),
                }
                try walkStatements(visitor, value.body);
            },
            .return_value => |value| if (value) |expr| {
                try walk(visitor, .{ .expression = expr });
            },
            .exported => |value| if (value.value) |expr| {
                try walk(visitor, .{ .expression = expr });
            },
            else => {},
        },
        .expression => |expression| switch (expression.value) {
            inline .quantity, .unary => |value| try walk(visitor, .{ .expression = value.operand }),
            .grouped => |value| try walk(visitor, .{ .expression = value }),
            .list => |values| for (values) |value| {
                try walk(visitor, .{ .expression = value });
            },
            .dict => |values| for (values) |value| {
                try walk(visitor, .{ .expression = value.value });
            },
            .vector => |value| {
                try walk(visitor, .{ .expression = value.x });
                try walk(visitor, .{ .expression = value.y });
                if (value.z) |z| try walk(visitor, .{ .expression = z });
            },
            inline .binary, .path_join, .path_literal => |value| {
                try walk(visitor, .{ .expression = value.left });
                try walk(visitor, .{ .expression = value.right });
            },
            inline .call, .mixfix_call => |value| for (value.args) |argument| {
                try walk(visitor, .{ .expression = argument });
            },
            .index => |value| {
                try walk(visitor, .{ .expression = value.object });
                try walk(visitor, .{ .expression = value.index });
            },
            .slice => |value| {
                try walk(visitor, .{ .expression = value.object });
                try walk(visitor, .{ .expression = value.range.start });
                if (value.range.step) |expr| try walk(visitor, .{ .expression = expr });
                if (value.range.stop) |expr| try walk(visitor, .{ .expression = expr });
            },
            .member => |value| try walk(visitor, .{ .expression = value.object }),
            .block => |body| try walkStatements(visitor, body),
            .expansion => |value| {
                for (value.args) |arg| try walk(visitor, .{ .expression = arg });
                try walkStatements(visitor, value.body);
            },

            else => {},
        },
    }
}
