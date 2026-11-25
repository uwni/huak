//! Tests of the affine constraint solver: free and dependent variables, contradiction witnesses, scaling, tolerance, invalid input and allocation failure.
const std = @import("std");
const constraints = @import("solver.zig");

test "coupled affine scalar equations and duplicate terms" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .constant = 1, .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 } } }, .number(12));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = -1 } } }, .number(1));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(constraints.Status.unique, solution.status);
    try std.testing.expectEqual(@as(usize, 2), solution.rank);
    try std.testing.expectApproxEqAbs(@as(f64, 4), solution.values[x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), solution.values[y].?, 1e-12);
}

test "unknown points preserve free dependencies until constrained" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const b = try solver.newPoint();
    const c = try solver.newPoint();
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = b.x, .coefficient = 1 }} }, .{ .terms = &.{.{ .variable = c.x, .coefficient = 2 }} });
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = b.y, .coefficient = 1 }} }, .number(0));
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = c.y, .coefficient = 1 }} }, .number(50));
    var partial = try solver.solve();
    defer partial.deinit();
    try std.testing.expectEqual(constraints.Status.underdetermined, partial.status);
    try std.testing.expectEqualSlices(constraints.Var, &.{c.x}, partial.free_variables);
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
    try std.testing.expectEqual(constraints.Status.unique, complete.status);
    try std.testing.expectApproxEqAbs(@as(f64, 60), complete.values[b.x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 30), complete.values[c.x].?, 1e-12);
    // A previous solution owns its expressions independently of later solves.
    try std.testing.expectEqual(constraints.Status.underdetermined, partial.status);
}

test "redundant and contradictory equations report a source witness" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = 1 }} }, .number(7));
    _ = try solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = 2 }} }, .number(14));
    var redundant = try solver.solve();
    defer redundant.deinit();
    try std.testing.expectEqual(constraints.Status.unique, redundant.status);
    const contradiction = try solver.addEquation(.{ .terms = &.{.{ .variable = x, .coefficient = 1 }} }, .number(8));
    var bad = try solver.solve();
    defer bad.deinit();
    try std.testing.expectEqual(constraints.Status.inconsistent, bad.status);
    try std.testing.expectEqual(contradiction, bad.inconsistent_equation.?);
    try std.testing.expectApproxEqAbs(@as(f64, 1), bad.residual, 1e-12);
    try std.testing.expectError(error.InconsistentSystem, bad.evaluate(std.testing.allocator, &.{}));
}

test "row normalization handles very small and large equation scales" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1e-250 }, .{ .variable = y, .coefficient = 1e-250 } } }, .number(5e-250));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 2e250 }, .{ .variable = y, .coefficient = -1e250 } } }, .number(4e250));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(constraints.Status.unique, solution.status);
    try std.testing.expectApproxEqAbs(@as(f64, 3), solution.values[x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), solution.values[y].?, 1e-12);
}

test "configurable tolerance diagnoses a near-dependent system" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 } } }, .number(2));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 + 1e-12 } } }, .number(2 + 1e-12));
    var approximate = try solver.solve();
    defer approximate.deinit();
    try std.testing.expectEqual(constraints.Status.underdetermined, approximate.status);
    solver.tolerance = .{ .absolute = 1e-15, .relative = 1e-15 };
    var strict = try solver.solve();
    defer strict.deinit();
    try std.testing.expectEqual(constraints.Status.unique, strict.status);
    try std.testing.expectApproxEqAbs(@as(f64, 1), strict.values[x].?, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1), strict.values[y].?, 1e-10);
}

test "text box metrics become constants in geometry constraints" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
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
    try std.testing.expectEqual(constraints.Status.unique, solution.status);
    try std.testing.expectApproxEqAbs(@as(f64, 25.25), solution.values[left].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 74.75), solution.values[right].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 29.25), solution.values[baseline].?, 1e-12);
}

test "empty, entirely free and constant-only systems" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    var empty = try solver.solve();
    defer empty.deinit();
    try std.testing.expectEqual(constraints.Status.unique, empty.status);
    const x = try solver.newScalar();
    var free = try solver.solve();
    defer free.deinit();
    try std.testing.expectEqual(constraints.Status.underdetermined, free.status);
    try std.testing.expectEqualSlices(constraints.Var, &.{x}, free.free_variables);
    _ = try solver.addEquation(.number(1), .number(1));
    _ = try solver.addEquation(.number(1), .number(2));
    var contradiction = try solver.solve();
    defer contradiction.deinit();
    try std.testing.expectEqual(constraints.Status.inconsistent, contradiction.status);
    try std.testing.expectEqual(@as(usize, 1), contradiction.inconsistent_equation.?);
}

test "a constant-only contradiction is invariant under rescaling" {
    for ([_]f64{ 1e-250, 1, 1e250 }) |rhs| {
        var solver = constraints.Solver.init(std.testing.allocator, .{});
        defer solver.deinit();
        _ = try solver.addEquation(.number(0), .number(rhs));
        var solution = try solver.solve();
        defer solution.deinit();
        try std.testing.expectEqual(constraints.Status.inconsistent, solution.status);
        try std.testing.expectEqual(@as(f64, 1), solution.residual);
    }
}

test "reject invalid variables, nonfinite data, overflow and bad evaluation" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
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
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const x = try solver.newScalar();
    const y = try solver.newScalar();
    var borrowed = [_]constraints.Term{ .{ .variable = x, .coefficient = 0 }, .{ .variable = y, .coefficient = 1 } };
    _ = try solver.addEquation(.{ .terms = &borrowed }, .number(4));
    // This mutation cannot alter the stored first equation.
    borrowed[1].coefficient = 100;
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = x, .coefficient = 1 }, .{ .variable = y, .coefficient = 1 } } }, .number(7));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(constraints.Status.unique, solution.status);
    try std.testing.expectApproxEqAbs(@as(f64, 3), solution.values[x].?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), solution.values[y].?, 1e-12);
}

test "dependencies on an earlier free column survive pivot operations" {
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    const u = try solver.newScalar();
    const v = try solver.newScalar();
    const w = try solver.newScalar();
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = u, .coefficient = 1e-12 }, .{ .variable = v, .coefficient = 2 }, .{ .variable = w, .coefficient = 1 } } }, .number(5));
    _ = try solver.addEquation(.{ .terms = &.{ .{ .variable = u, .coefficient = 2e-12 }, .{ .variable = v, .coefficient = 1 }, .{ .variable = w, .coefficient = 2 } } }, .number(7));
    var solution = try solver.solve();
    defer solution.deinit();
    try std.testing.expectEqual(constraints.Status.underdetermined, solution.status);
    try std.testing.expectEqualSlices(constraints.Var, &.{u}, solution.free_variables);
    const chosen = try solution.evaluate(std.testing.allocator, &.{1e12});
    defer std.testing.allocator.free(chosen);
    try std.testing.expectApproxEqAbs(@as(f64, 5), 1e-12 * chosen[u] + 2 * chosen[v] + chosen[w], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), 2e-12 * chosen[u] + chosen[v] + 2 * chosen[w], 1e-12);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var solver = constraints.Solver.init(allocator, .{});
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
    var solver = constraints.Solver.init(std.testing.allocator, .{});
    defer solver.deinit();
    solver.variable_count = std.math.maxInt(usize);
    try std.testing.expectError(error.TooManyVariables, solver.newScalar());
    try std.testing.expectError(error.TooManyVariables, solver.newPoint());
    try std.testing.expectEqual(std.math.maxInt(usize), solver.variable_count);
    try std.testing.expectError(error.NumericalOverflow, solver.solve());
}
