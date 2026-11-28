//! Branches, loops, and return, break and continue.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Span = source.Span;
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const operators = @import("operators.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const symbols = @import("symbols.zig");
const Binding = symbols.Binding;

pub const Loop = struct {
    breaks: std.ArrayList(u32) = .empty,
    continues: std.ArrayList(u32) = .empty,
    stack_depth: usize,
};

/// Returns, loop exits, conditionals and loops.
pub fn compileControl(self: *Compiler, context: *Context, statement_: *ast.Stmt) anyerror!void {
    const span = statement_.span;
    switch (statement_.value) {
        .return_value => |value| {
            if (context.entry and context.return_block == null) return self.fail(span, "return is only valid inside a function or block", .{});
            const actual = if (value) |expression| try expressions.compileExpression(self, context, expression) else blk: {
                try context.constant(.unit, span);
                break :blk Type.unit;
            };
            if (context.return_block) |block| {
                block.kind = if (block.kind) |previous| if (previous == actual) actual else .any else actual;
                _ = try context.emit(.store_local, block.slot, 0, span);

                const depth = context.stack_depth;
                defer context.stack_depth = depth;
                while (context.stack_depth > block.stack_depth) _ = try context.emit(.pop, 0, 0, span);
                try block.exits.append(self.build.syntax_allocator, try context.emit(.jump, 0, 0, span));
            } else {
                try self.require(context.result, actual, span);

                _ = try context.emit(.return_value, 0, 0, span);
            }
        },
        .break_loop, .continue_loop => {
            if (context.loops.items.len == 0) return self.fail(span, "{s} is only valid inside a loop", .{if (statement_.value == .break_loop) "break" else "continue"});
            const loop = context.loops.items[context.loops.items.len - 1];

            // Expressions may contain blocks. Discard their unfinished
            // operands before transferring control out of the expression.
            const depth = context.stack_depth;
            defer context.stack_depth = depth;
            while (context.stack_depth > loop.stack_depth) _ = try context.emit(.pop, 0, 0, span);
            const instruction = try context.emit(.jump, 0, 0, span);
            if (statement_.value == .break_loop) try loop.breaks.append(self.allocator, instruction) else try loop.continues.append(self.allocator, instruction);
        },
        .conditional => |conditional| {
            var exits: std.ArrayList(u32) = .empty;
            for (conditional.branches) |branch| {
                try self.require(.boolean, try expressions.compileExpression(self, context, branch.condition), branch.condition.span);
                const skip = try context.emit(.jump_if_false, 0, 0, branch.condition.span);
                try statements.compileStatements(self, context, branch.body);
                try exits.append(self.allocator, try context.emit(.jump, 0, 0, span));
                try context.patch(skip, context.code.items.len);
            }
            try statements.compileStatements(self, context, conditional.otherwise);
            for (exits.items) |exit| try context.patch(exit, context.code.items.len);
        },
        .while_loop => |while_loop| {
            const loop = try newLoop(self, context);
            const head = context.code.items.len;
            try self.require(.boolean, try expressions.compileExpression(self, context, while_loop.condition), while_loop.condition.span);
            const exit = try context.emit(.jump_if_false, 0, 0, span);
            try statements.compileStatements(self, context, while_loop.body);
            _ = try context.emit(.jump, try self.narrow(head, span), 0, span);
            try context.patch(exit, context.code.items.len);
            try finishLoop(self, context, loop, head);
        },
        .for_loop => |for_loop| try forLoop(self, context, for_loop, span),
        else => unreachable,
    }
}

pub fn newLoop(self: *Compiler, context: *Context) !*Loop {
    const loop = try self.allocator.create(Loop);
    loop.* = .{ .stack_depth = context.stack_depth };
    try context.loops.append(self.allocator, loop);
    return loop;
}

pub fn finishLoop(_: *Compiler, context: *Context, loop: *Loop, continue_target: usize) !void {
    for (loop.breaks.items) |instruction| try context.patch(instruction, context.code.items.len);
    for (loop.continues.items) |instruction| try context.patch(instruction, continue_target);
    _ = context.loops.pop();
}

pub fn forLoop(self: *Compiler, context: *Context, loop_: @FieldType(@FieldType(ast.Stmt, "value"), "for_loop"), span: Span) anyerror!void {
    const binding: Binding = .{ .symbol = context.locals.get(loop_.name_span.start).?, .local = true, .declaration = loop_.name_span.start };
    const kind: Type = switch (loop_.iterable) {
        .range => |range| range_type: {
            const first = try expressions.compileExpression(self, context, range.start);
            try self.require(.scalar, first, range.start.span);
            const stop = try expressions.compileExpression(self, context, range.stop.?);
            try self.require(.scalar, stop, range.stop.?.span);
            const step = if (range.step) |expression| try expressions.compileExpression(self, context, expression) else step_type: {
                try context.constant(.{ .int = 1 }, span);
                break :step_type Type.int;
            };
            try self.require(.scalar, step, span);
            _ = try operators.binaryType(self, .less_equal, first, stop, span);
            _ = try operators.binaryType(self, .add, first, step, span);
            break :range_type if (first == .any or stop == .any or step == .any) .any else if (first == .int and stop == .int and step == .int) .int else if (first == stop and first == step) first else if (first == .int or first == .number) .number else .scalar;
        },
        .collection => |expression| collection_type: {
            const collection = try expressions.compileExpression(self, context, expression);
            if (collection != .list and collection != .any)
                return self.fail(expression.span, "for requires a list or numeric range, found {s}", .{self.typeName(collection)});
            break :collection_type .any;
        },
    };
    // Iteration state belongs to this activation's locals, not the user
    // variable. Rebinding that variable never changes the next element.
    const state_kind: Type = if (loop_.iterable == .range) kind else .any;
    const current_slot = try context.temporary(state_kind, span);
    const stop_slot = try context.temporary(state_kind, span);
    const step_slot = try context.temporary(state_kind, span);
    _ = try context.emit(.iterate_init, @intFromBool(loop_.iterable == .collection), 0, span);
    _ = try context.emit(.store_local, step_slot, 0, span);
    _ = try context.emit(.store_local, stop_slot, 0, span);
    _ = try context.emit(.store_local, current_slot, 0, span);
    context.locals.getPtr(binding.declaration).?.kind = kind;
    context.locals.getPtr(binding.declaration).?.inferable = false;
    context.local_types.items[binding.symbol.index] = kind;
    const loop = try newLoop(self, context);
    const head = context.code.items.len;
    _ = try context.emit(.load_local, current_slot, 0, span);
    _ = try context.emit(.load_local, stop_slot, 0, span);
    _ = try context.emit(.load_local, step_slot, 0, span);
    _ = try context.emit(.iterate_test, 0, 0, span);
    const exit = try context.emit(.jump_if_false, 0, 0, span);
    try context.store(binding, span);
    try statements.compileStatements(self, context, loop_.body);
    const advance = context.code.items.len;
    _ = try context.emit(.load_local, current_slot, 0, span);
    _ = try context.emit(.load_local, stop_slot, 0, span);
    _ = try context.emit(.load_local, step_slot, 0, span);
    _ = try context.emit(.iterate_advance, 0, 0, span);
    const at_end = try context.emit(.jump_if_false, 0, 0, span);
    _ = try context.emit(.store_local, current_slot, 0, span);
    _ = try context.emit(.jump, try self.narrow(head, span), 0, span);
    // Both iterator exits leave a value that must be discarded.
    try context.patch(at_end, context.code.items.len);
    try context.patch(exit, context.code.items.len);
    context.stack_depth = loop.stack_depth + 1;
    _ = try context.emit(.pop, 0, 0, span);
    try finishLoop(self, context, loop, advance);
}
