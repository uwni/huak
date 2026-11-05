//! Independent affine constraints for huak's geometry engine.
//!
//! Equations retain sparse coefficients. Solving uses row-normalized dense
//! Gaussian elimination with partial pivoting; no rendering or language runtime
//! participates. A solution reports the remaining free variables explicitly.
const std = @import("std");

pub const Var = u32;
pub const PointVars = struct { x: Var, y: Var };
pub const Term = struct { variable: Var, coefficient: f64 };

/// Borrowed expression. addEquation copies its coefficients, so stack-backed
/// terms may be discarded or reused immediately after that call returns.
pub const LinearExpr = struct {
    constant: f64 = 0,
    terms: []const Term = &.{},

    pub fn number(value: f64) LinearExpr {
        return .{ .constant = value };
    }
};

/// Tolerances apply after each equation is normalized by its largest absolute
/// coefficient. This makes rank decisions invariant to rescaling an equation.
/// relative also accounts for the accumulated RHS magnitude when diagnosing a
/// contradictory row. Units and variable scaling remain the caller's concern.
pub const Tolerance = struct {
    absolute: f64 = 1e-12,
    relative: f64 = 1e-10,

    fn valid(self: Tolerance) bool {
        return std.math.isFinite(self.absolute) and std.math.isFinite(self.relative) and
            self.absolute >= 0 and self.relative >= 0 and
            std.math.isFinite(self.absolute + self.relative);
    }

    fn zero(self: Tolerance, value: f64, reference: f64) bool {
        return @abs(value) <= self.absolute + self.relative * reference;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidVariable,
    NonFinite,
    InvalidTolerance,
    TooManyVariables,
    NumericalOverflow,
    InvalidFreeValueCount,
    InconsistentSystem,
};

pub const Status = enum { unique, underdetermined, inconsistent };

/// variable = constant + sum(term.coefficient * free_variable).
/// A free variable's own expression is the identity term for that variable.
pub const SolvedExpr = struct {
    constant: f64,
    terms: []const Term,
};

pub const Solution = struct {
    allocator: std.mem.Allocator,
    status: Status,
    rank: usize,
    /// Known values independent of all free variables; null for dependent or
    /// free variables. All entries are null if the system is inconsistent.
    values: []?f64,
    /// Ordered by variable id; evaluate takes values in precisely this order.
    free_variables: []Var,
    /// One expression per variable, or empty for an inconsistent system.
    expressions: []SolvedExpr,
    /// Original equation index associated with a contradictory reduced row.
    /// That row is a combination of this equation and preceding pivot rows;
    /// the index identifies a witness, not necessarily the sole bad constraint.
    inconsistent_equation: ?usize = null,
    /// Normalized residual of that contradictory row.
    residual: f64 = 0,

    pub fn deinit(self: *Solution) void {
        for (self.expressions) |expression| self.allocator.free(expression.terms);
        self.allocator.free(self.expressions);
        self.allocator.free(self.free_variables);
        self.allocator.free(self.values);
        self.* = undefined;
    }

    /// Return owned scalar values for a chosen assignment of the free vars.
    pub fn evaluate(self: *const Solution, allocator: std.mem.Allocator, free_values: []const f64) Error![]f64 {
        if (self.status == .inconsistent) return error.InconsistentSystem;
        if (free_values.len != self.free_variables.len) return error.InvalidFreeValueCount;
        for (free_values) |value| if (!std.math.isFinite(value)) return error.NonFinite;
        const result = try allocator.alloc(f64, self.expressions.len);
        errdefer allocator.free(result);
        for (self.expressions, result) |expression, *value| {
            value.* = expression.constant;
            for (expression.terms) |term| {
                // Both lists are ordered. A binary search avoids allocating a
                // second full variable array just to assign the parameters.
                const index = std.sort.binarySearch(Var, self.free_variables, term.variable, compareVar).?;
                value.* += term.coefficient * free_values[index];
            }
            if (!std.math.isFinite(value.*)) return error.NumericalOverflow;
        }
        return result;
    }
};

fn compareVar(lhs: Var, rhs: Var) std.math.Order {
    return std.math.order(lhs, rhs);
}

const Equation = struct { terms: []Term, rhs: f64 };

pub const Solver = struct {
    allocator: std.mem.Allocator,
    tolerance: Tolerance,
    variable_count: usize = 0,
    equations: std.ArrayList(Equation) = .empty,

    pub fn init(allocator: std.mem.Allocator, tolerance: Tolerance) Solver {
        return .{ .allocator = allocator, .tolerance = tolerance };
    }

    pub fn deinit(self: *Solver) void {
        for (self.equations.items) |equation| self.allocator.free(equation.terms);
        self.equations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn newScalar(self: *Solver) Error!Var {
        if (self.variable_count > std.math.maxInt(Var)) return error.TooManyVariables;
        const next = std.math.add(usize, self.variable_count, 1) catch return error.TooManyVariables;
        const variable: Var = @intCast(self.variable_count);
        self.variable_count = next;
        return variable;
    }

    pub fn newPoint(self: *Solver) Error!PointVars {
        if (self.variable_count >= std.math.maxInt(Var)) return error.TooManyVariables;
        const next = std.math.add(usize, self.variable_count, 2) catch return error.TooManyVariables;
        const point = PointVars{ .x = @intCast(self.variable_count), .y = @intCast(self.variable_count + 1) };
        self.variable_count = next;
        return point;
    }

    /// Adds lhs = rhs and returns its stable zero-based equation index.
    /// Duplicate terms are combined; exact zeros are discarded. No tolerance
    /// is applied here, so tiny but well-scaled equations retain their meaning.
    pub fn addEquation(self: *Solver, lhs: LinearExpr, rhs: LinearExpr) Error!usize {
        if (!std.math.isFinite(lhs.constant) or !std.math.isFinite(rhs.constant)) return error.NonFinite;
        const constant = rhs.constant - lhs.constant;
        if (!std.math.isFinite(constant)) return error.NumericalOverflow;
        const coefficients = try self.allocator.alloc(f64, self.variable_count);
        defer self.allocator.free(coefficients);
        @memset(coefficients, 0);
        try self.accumulate(coefficients, lhs.terms, 1);
        try self.accumulate(coefficients, rhs.terms, -1);
        var count: usize = 0;
        for (coefficients) |coefficient| if (coefficient != 0) {
            count += 1;
        };
        const terms = try self.allocator.alloc(Term, count);
        errdefer self.allocator.free(terms);
        var index: usize = 0;
        for (coefficients, 0..) |coefficient, variable| {
            if (coefficient != 0) {
                terms[index] = .{ .variable = @intCast(variable), .coefficient = coefficient };
                index += 1;
            }
        }
        const equation_index = self.equations.items.len;
        try self.equations.append(self.allocator, .{ .terms = terms, .rhs = constant });
        return equation_index;
    }

    fn accumulate(self: *const Solver, coefficients: []f64, terms: []const Term, sign: f64) Error!void {
        for (terms) |term| {
            if (term.variable >= self.variable_count) return error.InvalidVariable;
            if (!std.math.isFinite(term.coefficient)) return error.NonFinite;
            coefficients[term.variable] += sign * term.coefficient;
            if (!std.math.isFinite(coefficients[term.variable])) return error.NumericalOverflow;
        }
    }

    /// Produces an independent owned snapshot; further equations can be added
    /// and solved without invalidating any previous Solution.
    pub fn solve(self: *const Solver) Error!Solution {
        if (!self.tolerance.valid()) return error.InvalidTolerance;
        const allocator = self.allocator;
        const rows = self.equations.items.len;
        const columns = self.variable_count;
        const stride = std.math.add(usize, columns, 1) catch return error.NumericalOverflow;
        const matrix_length = std.math.mul(usize, rows, stride) catch return error.NumericalOverflow;
        const matrix = try allocator.alloc(f64, matrix_length);
        defer allocator.free(matrix);
        @memset(matrix, 0);
        const rhs_scales = try allocator.alloc(f64, rows);
        defer allocator.free(rhs_scales);
        const sources = try allocator.alloc(usize, rows);
        defer allocator.free(sources);
        const pivots = try allocator.alloc(usize, @min(rows, columns));
        defer allocator.free(pivots);

        for (self.equations.items, 0..) |equation, row| {
            var scale: f64 = 0;
            for (equation.terms) |term| scale = @max(scale, @abs(term.coefficient));
            // A nonzero constant-only equation is a contradiction regardless
            // of its units or magnitude; normalize its RHS rather than silently
            // accepting 0 = 1e-250 as an approximately redundant equation.
            if (scale == 0) scale = if (equation.rhs == 0) 1 else @abs(equation.rhs);
            for (equation.terms) |term| matrix[row * stride + term.variable] = term.coefficient / scale;
            const rhs = equation.rhs / scale;
            if (!std.math.isFinite(rhs)) return error.NumericalOverflow;
            matrix[row * stride + columns] = rhs;
            rhs_scales[row] = @abs(rhs);
            sources[row] = row;
        }

        var rank: usize = 0;
        for (0..columns) |column| {
            if (rank == rows) break;
            var best = rank;
            for (rank + 1..rows) |candidate| {
                if (@abs(matrix[candidate * stride + column]) > @abs(matrix[best * stride + column])) best = candidate;
            }
            if (self.tolerance.zero(matrix[best * stride + column], 1)) continue;
            if (best != rank) {
                for (0..stride) |j| std.mem.swap(f64, &matrix[rank * stride + j], &matrix[best * stride + j]);
                std.mem.swap(f64, &rhs_scales[rank], &rhs_scales[best]);
                std.mem.swap(usize, &sources[rank], &sources[best]);
            }
            const pivot = matrix[rank * stride + column];
            // Earlier skipped columns are free variables and may contain small
            // coefficients. Transform them too, so parametric dependencies are
            // not lost merely because a column did not supply a pivot.
            for (0..stride) |j| {
                matrix[rank * stride + j] /= pivot;
                if (!std.math.isFinite(matrix[rank * stride + j])) return error.NumericalOverflow;
            }
            matrix[rank * stride + column] = 1;
            rhs_scales[rank] /= @abs(pivot);
            if (!std.math.isFinite(rhs_scales[rank])) return error.NumericalOverflow;

            for (0..rows) |row| {
                if (row == rank) continue;
                const factor = matrix[row * stride + column];
                matrix[row * stride + column] = 0;
                if (factor == 0) continue;
                for (0..stride) |j| {
                    if (j == column) continue;
                    matrix[row * stride + j] -= factor * matrix[rank * stride + j];
                    if (!std.math.isFinite(matrix[row * stride + j])) return error.NumericalOverflow;
                }
                rhs_scales[row] += @abs(factor) * rhs_scales[rank];
                if (!std.math.isFinite(rhs_scales[row])) return error.NumericalOverflow;
            }
            pivots[rank] = column;
            rank += 1;
        }

        var inconsistent: ?usize = null;
        var residual: f64 = 0;
        for (rank..rows) |row| {
            const rhs = matrix[row * stride + columns];
            if (!self.tolerance.zero(rhs, rhs_scales[row])) {
                inconsistent = sources[row];
                residual = rhs;
                break;
            }
        }

        const values = try allocator.alloc(?f64, columns);
        errdefer allocator.free(values);
        @memset(values, null);
        const free_variables = try allocator.alloc(Var, if (inconsistent != null) 0 else columns - rank);
        errdefer allocator.free(free_variables);
        const expressions = try allocator.alloc(SolvedExpr, if (inconsistent != null) 0 else columns);
        for (expressions) |*expression| expression.* = .{ .constant = 0, .terms = &.{} };
        errdefer {
            for (expressions) |expression| allocator.free(expression.terms);
            allocator.free(expressions);
        }

        if (inconsistent == null) {
            var pivot_index: usize = 0;
            var free_index: usize = 0;
            for (0..columns) |variable| {
                if (pivot_index < rank and pivots[pivot_index] == variable) {
                    pivot_index += 1;
                } else {
                    free_variables[free_index] = @intCast(variable);
                    free_index += 1;
                }
            }
            pivot_index = 0;
            for (expressions, 0..) |*expression, variable| {
                if (pivot_index < rank and pivots[pivot_index] == variable) {
                    const row = matrix[pivot_index * stride ..][0..stride];
                    expression.constant = row[columns];
                    var count: usize = 0;
                    for (free_variables) |free| if (row[free] != 0) {
                        count += 1;
                    };
                    const terms = try allocator.alloc(Term, count);
                    var index: usize = 0;
                    for (free_variables) |free| {
                        if (row[free] != 0) {
                            terms[index] = .{ .variable = free, .coefficient = -row[free] };
                            index += 1;
                        }
                    }
                    expression.terms = terms;
                    if (count == 0) values[variable] = expression.constant;
                    pivot_index += 1;
                } else {
                    const terms = try allocator.alloc(Term, 1);
                    terms[0] = .{ .variable = @intCast(variable), .coefficient = 1 };
                    expression.terms = terms;
                }
            }
        }
        return .{
            .allocator = allocator,
            .status = if (inconsistent != null) .inconsistent else if (rank == columns) .unique else .underdetermined,
            .rank = rank,
            .values = values,
            .free_variables = free_variables,
            .expressions = expressions,
            .inconsistent_equation = inconsistent,
            .residual = residual,
        };
    }
};

test "coupled affine scalar equations and duplicate terms" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .constant = 1, .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 } } }, .number(12));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = -1 } } }, .number(1));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(Status.unique, solution.status);
    try std.testing.expectEqual(@as(usize, 2), solution.rank);
    try std.testing.expectApproxEqAbs(@as(f64, 4), solution.values[x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), solution.values[y].?, 1e-12);
}

test "unknown points preserve free dependencies until constrained" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const b = try solver.newPoint();
    const c = try solver.newPoint();
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = b.x, .coefficient = 1 }} }, .{ .terms = &.{.{ .variable = c.x, .coefficient = 2 }} });
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = b.y, .coefficient = 1 }} }, .number(0));
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = c.y, .coefficient = 1 }} }, .number(50));
    var partial = try solver.solve();
    defer partial.deinit();
    try std.testing.expectEqual(Status.underdetermined, partial.status);
    try std.testing.expectEqualSlices(Var, &.{c.x}, partial.free_variables);
    try std.testing.expect(partial.values[b.x] == null);
    try std.testing.expectEqual(@as(f64, 0), partial.values[b.y].?);
    try std.testing.expectEqual(@as(f64, 50), partial.values[c.y].?);
    try std.testing.expectEqual(@as(usize, 1), partial.expressions[b.x].terms.len);
    try std.testing.expectEqual(@as(f64, 2), partial.expressions[b.x].terms[0].coefficient);
    const chosen = try partial.evaluate(std.testing.allocator, &.{30});
    defer std.testing.allocator.free(chosen);
    try std.testing.expectEqualSlices(f64, &.{ 60, 0, 30, 50 }, chosen);
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = b.x, .coefficient = 1 }, .{ .variable = c.x, .coefficient = 1 } } }, .number(90));
    var complete = try solver.solve();
    defer complete.deinit();
    try std.testing.expectEqual(Status.unique, complete.status);
    try std.testing.expectApproxEqAbs(@as(f64, 60), complete.values[b.x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 30), complete.values[c.x].?, 1e-12);
    // A previous solution owns its expressions independently of later solves.
    try std.testing.expectEqual(Status.underdetermined, partial.status);
}

test "redundant and contradictory equations report a source witness" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = 1 }} }, .number(7));
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = 2 }} }, .number(14));
    var redundant = try solver.solve();
    defer redundant.deinit();
    try std.testing.expectEqual(Status.unique, redundant.status);
    const contradiction = try solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = 1 }} }, .number(8));
    var bad = try solver.solve();
    defer bad.deinit();
    try std.testing.expectEqual(Status.inconsistent, bad.status);
    try std.testing.expectEqual(contradiction, bad.inconsistent_equation.?);
    try std.testing.expectApproxEqAbs(@as(f64, 1), bad.residual, 1e-12);
    try std.testing.expectError(error.InconsistentSystem, bad.evaluate(std.testing.allocator, &.{}));
}

test "row normalization handles very small and large equation scales" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1e-250 }, .{ .variable = y, .coefficient = 1e-250 } } }, .number(5e-250));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 2e250 }, .{ .variable = y, .coefficient = -1e250 } } }, .number(4e250));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(Status.unique, solution.status);
    try std.testing.expectApproxEqAbs(@as(f64, 3), solution.values[x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), solution.values[y].?, 1e-12);
}

test "configurable tolerance diagnoses a near-dependent system" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 } } }, .number(2));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 + 1e-12 } } }, .number(2 + 1e-12));
    var approximate = try solver.solve();
    defer approximate.deinit();
    try std.testing.expectEqual(Status.underdetermined, approximate.status);
    solver.tolerance = .{ .absolute = 1e-15, .relative = 1e-15 };
    var strict = try solver.solve();
    defer strict.deinit();
    try std.testing.expectEqual(Status.unique, strict.status);
    try std.testing.expectApproxEqAbs(@as(f64, 1), strict.values[x].?, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1), strict.values[y].?, 1e-10);
}

test "text box metrics become constants in geometry constraints" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const left = try solver.newScalar();
    const right = try solver.newScalar();
    const baseline = try solver.newScalar();
    const top = try solver.newScalar();
    // The renderer supplies these metrics; the solver has no Typst dependency.
    const width = 37.5;
    const ascent = 9.25;
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = right, .coefficient = 1 }, .{ .variable = left, .coefficient = -1 } } }, .number(width + 12));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = right, .coefficient = 1 }, .{ .variable = left, .coefficient = 1 } } }, .number(100));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = baseline, .coefficient = 1 }, .{ .variable = top, .coefficient = -1 } } }, .number(ascent));
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = top, .coefficient = 1 }} }, .number(20));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(Status.unique, solution.status);
    try std.testing.expectApproxEqAbs(@as(f64, 25.25), solution.values[left].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 74.75), solution.values[right].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 29.25), solution.values[baseline].?, 1e-12);
}

test "empty, entirely free and constant-only systems" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    var empty = try solver.solve();
    defer empty.deinit();
    try std.testing.expectEqual(Status.unique, empty.status);
    const x = try solver.newScalar();
    var free = try solver.solve();
    defer free.deinit();
    try std.testing.expectEqual(Status.underdetermined, free.status);
    try std.testing.expectEqualSlices(Var, &.{x}, free.free_variables);
    _ = try solver.addEquation(.number(1), .number(1));
    _ = try solver.addEquation(.number(1), .number(2));
    var contradiction = try solver.solve();
    defer contradiction.deinit();
    try std.testing.expectEqual(Status.inconsistent, contradiction.status);
    try std.testing.expectEqual(@as(usize, 1), contradiction.inconsistent_equation.?);
}

test "a constant-only contradiction is invariant under rescaling" {
    for ([_]f64{ 1e-250, 1, 1e250 }) |rhs| {
        var solver = Solver.init(std.testing.allocator, .{});
        defer solver.deinit();
        _ = try solver.addEquation(.number(0), .number(rhs));
        var solution = try solver.solve();
        defer solution.deinit();
        try std.testing.expectEqual(Status.inconsistent, solution.status);
        try std.testing.expectEqual(@as(f64, 1), solution.residual);
    }
}

test "reject invalid variables, nonfinite data, overflow and bad evaluation" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    try std.testing.expectError(error.InvalidVariable, solver.addEquation(.{ .terms = &.{.{ .variable = 9, .coefficient = 1 }} }, .number(1)));
    try std.testing.expectError(error.NonFinite, solver.addEquation(.number(std.math.nan(f64)), .number(1)));
    try std.testing.expectError(error.NonFinite, solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = std.math.inf(f64) }} }, .number(1)));
    try std.testing.expectError(error.NumericalOverflow, solver.addEquation(.number(-1e308), .number(1e308)));
    try std.testing.expectEqual(@as(usize, 0), solver.equations.items.len);
    var free = try solver.solve();
    defer free.deinit();
    try std.testing.expectError(error.InvalidFreeValueCount, free.evaluate(std.testing.allocator, &.{}));
    try std.testing.expectError(error.NonFinite, free.evaluate(std.testing.allocator, &.{std.math.nan(f64)}));
    solver.tolerance.absolute = -1;
    try std.testing.expectError(error.InvalidTolerance, solver.solve());
}

test "partial pivoting and expression copying keep later constraints correct" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    var borrowed = [_]Term{ .{ .variable = x, .coefficient = 0 }, .{ .variable = y, .coefficient = 1 } };
    _ = try solver.addEquation(.{ .terms = &borrowed }, .number(4));
    // This mutation cannot alter the stored first equation.
    borrowed[1].coefficient = 100;
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 } } }, .number(7));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(Status.unique, solution.status);
    try std.testing.expectApproxEqAbs(@as(f64, 3), solution.values[x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), solution.values[y].?, 1e-12);
}

test "dependencies on an earlier free column survive pivot operations" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const u = try solver.newScalar();
    const v = try solver.newScalar();
    const w = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = u, .coefficient = 1e-12 }, .{ .variable = v, .coefficient = 2 }, .{ .variable = w, .coefficient = 1 } } }, .number(5));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = u, .coefficient = 2e-12 }, .{ .variable = v, .coefficient = 1 }, .{ .variable = w, .coefficient = 2 } } }, .number(7));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(Status.underdetermined, solution.status);
    try std.testing.expectEqualSlices(Var, &.{u}, solution.free_variables);
    const chosen = try solution.evaluate(std.testing.allocator, &.{1e12});
    defer std.testing.allocator.free(chosen);
    try std.testing.expectApproxEqAbs(@as(f64, 5), 1e-12 * chosen[u] + 2 * chosen[v] + chosen[w], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), 2e-12 * chosen[u] + chosen[v] + 2 * chosen[w], 1e-12);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var solver = Solver.init(allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 2 } } }, .number(3));
    var result = try solver.solve();
    defer result.deinit();
    const evaluated = try result.evaluate(allocator, &.{1});
    defer allocator.free(evaluated);
    try std.testing.expectEqualSlices(f64, &.{ 1, 1 }, evaluated);
}

test "allocation failures clean up equations and partial solution snapshots" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "oversized variable metadata fails before count or matrix stride overflow" {
    var solver = Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    solver.variable_count = std.math.maxInt(usize);
    try std.testing.expectError(error.TooManyVariables, solver.newScalar());
    try std.testing.expectError(error.TooManyVariables, solver.newPoint());
    try std.testing.expectEqual(std.math.maxInt(usize), solver.variable_count);
    try std.testing.expectError(error.NumericalOverflow, solver.solve());
}
