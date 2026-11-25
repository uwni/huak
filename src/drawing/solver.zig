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

test {
    _ = @import("solver_test.zig");
}
