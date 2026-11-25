//! The linear solver: expressions, variables, solutions, the host's linear operators and the solver builtins.
const std = @import("std");
const constraints = @import("../../drawing/solver.zig");
const bc = @import("../bytecode.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const checkedIndex = conversions.checkedIndex;
const number = conversions.number;
const numeric = conversions.numeric;
const from = Runtime.from;

pub const Expr = struct { owner: ?usize, expression: constraints.LinearExpr };

pub const Variable = struct { owner: usize, id: constraints.Var };

pub const Solved = struct { owner: usize, solution: constraints.Solution };

fn mutableSolver(self: *Runtime, index: usize) !*constraints.Solver {
    if (index < self.firstOwned("solvers")) return error.TaskCannotMutateBorrowedSolver;
    return self.solvers.items[index];
}

/// The linear solver.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .solver => {
            const value = try self.gpa.create(constraints.Solver);
            errdefer self.gpa.destroy(value);
            value.* = .init(self.gpa, .{});
            errdefer value.deinit();
            return conversions.store(self, *constraints.Solver, &self.solvers, value, .solver);
        },
        .unknown => {
            const owner = try checkedIndex(arg.solver, .solver, self.solvers.items.len);
            return conversions.store(self, Variable, &self.variables, .{ .owner = owner, .id = try (try mutableSolver(self, owner)).newScalar() }, .variable);
        },
        .equation => {
            const owner = try checkedIndex(arg.solver, .solver, self.solvers.items.len);
            var lhs_term: [1]constraints.Term = undefined;
            var rhs_term: [1]constraints.Term = undefined;
            const lhs = try expr(self, arg.left, &lhs_term);
            const rhs = try expr(self, arg.right, &rhs_term);
            if ((lhs.owner != null and lhs.owner != owner) or (rhs.owner != null and rhs.owner != owner)) return error.DifferentSolvers;
            _ = try (try mutableSolver(self, owner)).addEquation(lhs.expression, rhs.expression);
            return .unit;
        },
        .solve => {
            const owner = try checkedIndex(arg.solver, .solver, self.solvers.items.len);
            // Solving only reads the solver, so workers can solve a borrowed
            // one; the solution uses the solver's allocator, which supports
            // concurrent use, and belongs to this runtime.
            var result = try self.solvers.items[owner].solve();
            errdefer result.deinit();
            return conversions.store(self, Solved, &self.solutions, .{ .owner = owner, .solution = result }, .solution);
        },
        .value => {
            const result = self.solutions.items[try checkedIndex(arg.solution, .solution, self.solutions.items.len)];
            const variable = self.variables.items[try checkedIndex(arg.variable, .variable, self.variables.items.len)];
            if (result.owner != variable.owner) return error.DifferentSolvers;
            if (result.solution.status == .inconsistent) return error.InconsistentSystem;
            if (variable.id >= result.solution.values.len) return error.InvalidVariable;
            return number(result.solution.values[variable.id] orelse return error.UnderdeterminedVariable);
        },
        else => comptime unreachable,
    }
}

/// A variable reads as one term, held in `single` for the caller's use.
fn expr(self: *Runtime, v: Value, single: *[1]constraints.Term) !Expr {
    if (v.valueType() == .variable) {
        const variable = self.variables.items[try checkedIndex(v, .variable, self.variables.items.len)];
        single[0] = .{ .variable = variable.id, .coefficient = 1 };
        return .{ .owner = variable.owner, .expression = .{ .terms = single } };
    }
    if (v.valueType() == .linear) return self.expressions.items[try checkedIndex(v, .linear, self.expressions.items.len)];
    return .{ .owner = null, .expression = .number(try numeric(v)) };
}

pub fn binary(ctx: ?*anyopaque, _: std.mem.Allocator, op: bc.Op, lhs: Value, rhs: Value) !Value {
    const self = from(ctx);
    var left_term: [1]constraints.Term = undefined;
    var right_term: [1]constraints.Term = undefined;
    const left = try expr(self, lhs, &left_term);
    const right = try expr(self, rhs, &right_term);
    if (left.owner != null and right.owner != null and left.owner != right.owner) return error.DifferentSolvers;
    var result: Expr = .{ .owner = left.owner orelse right.owner, .expression = .{} };
    const gpa = self.gpa;
    const terms = switch (op) {
        .add, .subtract => terms: {
            const terms = try gpa.alloc(constraints.Term, left.expression.terms.len + right.expression.terms.len);
            @memcpy(terms[0..left.expression.terms.len], left.expression.terms);
            const sign: f64 = if (op == .add) 1 else -1;
            for (right.expression.terms, terms[left.expression.terms.len..]) |t, *out| out.* = .{ .variable = t.variable, .coefficient = t.coefficient * sign };
            result.expression = .{ .constant = left.expression.constant + sign * right.expression.constant, .terms = terms };
            break :terms terms;
        },
        .multiply, .divide => terms: {
            if ((left.owner != null and right.owner != null) or (op == .divide and right.owner != null)) return error.NonlinearExpression;
            const expression = if (left.owner != null) left.expression else right.expression;
            const scalar = if (left.owner != null) right.expression.constant else left.expression.constant;
            if (op == .divide and scalar == 0) return error.DivisionByZero;
            const terms = try gpa.dupe(constraints.Term, expression.terms);
            for (terms) |*term| term.coefficient = if (op == .divide) term.coefficient / scalar else term.coefficient * scalar;
            result.expression = .{ .constant = if (op == .divide) expression.constant / scalar else expression.constant * scalar, .terms = terms };
            break :terms terms;
        },
        else => return error.UnsupportedOperator,
    };
    errdefer gpa.free(terms);
    if (!std.math.isFinite(result.expression.constant)) return error.NonFinite;
    for (result.expression.terms) |term| if (!std.math.isFinite(term.coefficient)) return error.NonFinite;
    return conversions.store(self, Expr, &self.expressions, result, .linear);
}
