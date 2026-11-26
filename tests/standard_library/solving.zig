//! Linear constraint blocks: scoped `==` mixfix equations, nested solvers, single target evaluation and diagnostics.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

test "solving blocks express linear equations with mixfix == and keep outer equality intact" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import assertions.assert
        \\import math.abs
        \\import std.solving.solving
        \\import solver.{unknown, value}
        \\calls := 0
        \\s := solver()
        \\fn pick() -> solver
        \\    calls = calls + 1
        \\    return s
        \\end
        \\u := unknown(s); v := unknown(s)
        \\other := solver()
        \\w := unknown(other)
        \\answer := solving pick() do
        \\    2 * u + v == 8
        \\    inner := solving other do
        \\        3 * w - 6 == 9
        \\    end
        \\    assert(abs(value(inner, w) - 5) < 1e-9)
        \\    u - v == 1
        \\end
        \\assert(calls == 1)
        \\assert(answer.status == "unique" and answer.rank == 2)
        \\assert(abs(value(answer, u) - 3) < 1e-9)
        \\assert(abs(value(answer, v) - 2) < 1e-9)
        \\assert(1 + 1 == 2)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
}

test "solving blocks support early return and diagnose non-solver targets and cross-solver variables" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const early =
        \\import assertions.assert
        \\import solving.solving
        \\import solver.{unknown, solve, value}
        \\s := solver()
        \\x := unknown(s)
        \\fn abort_early(target:solver, v:variable) -> int
        \\    return solving target do
        \\        v == 7
        \\        return 42
        \\    end
        \\end
        \\assert(abort_early(s, x) == 42)
        \\assert(value(solve(s), x) == 7)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, early, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);

        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, "import solving.solving; solving 1 do end", "bad-target.huak", .{ .optimize = optimize }, &diagnostic));
        try t.expect(diagnostic != null);

        var cross = try compile(&library,
            \\import solving.solving
            \\import solver.unknown
            \\s := solver(); other := solver()
            \\x := unknown(s); y := unknown(other)
            \\solving s do x == y end
        , optimize);
        defer cross.deinit();
        var cross_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer cross_runtime.deinit();
        var cross_machine = try l.Machine.init(t.allocator, &cross, cross_runtime.host(), .{});
        defer cross_machine.deinit();
        try t.expectError(error.RuntimeFailed, cross_machine.execute(&.{}));
        try t.expect(std.mem.indexOf(u8, cross_machine.failure.?.text(), "DifferentSolvers") != null or
            std.mem.indexOf(u8, cross_machine.failure.?.native_message, "solver") != null);
    }
}
