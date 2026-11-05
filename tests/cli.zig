//! Acceptance through the actual CLI, native DSO, SVG parser and PDF tools.
const std = @import("std");
const Harness = @import("cli/harness.zig").Harness;
test "watch rebuilds actual modules fonts and missing files without restarting" {
    var context = try Harness.init();
    defer context.deinit();
    try @import("cli/watch.zig").run(&context);
}

test "CLI processes preserve parameters visibility modules operators units and native exports" {
    var context = try Harness.init();
    defer context.deinit();
    try @import("cli/parameters.zig").run(&context);
    try @import("cli/exports.zig").run(&context);
    try @import("cli/modules.zig").run(&context);
    try @import("cli/imports.zig").run(&context);
    try @import("cli/variadic.zig").run(&context);
    try @import("cli/scopes.zig").run(&context);
    try @import("cli/slices.zig").run(&context);
    try @import("cli/mixfix.zig").run(&context);
    try @import("cli/assertions.zig").run(&context);
    try @import("cli/optimization.zig").run(&context);
    try @import("cli/operators.zig").run(&context);
    try @import("cli/prefix_units.zig").run(&context);
    try @import("cli/polygon.zig").run(&context);
    try @import("cli/path_queries.zig").run(&context);
    try @import("cli/weave.zig").run(&context);
    try @import("cli/batch.zig").run(&context);
    try @import("cli/workers.zig").run(&context);
    try @import("cli/exposures.zig").run(&context);
    try @import("cli/envelopes.zig").run(&context);
    try @import("cli/composition.zig").run(&context);
    try context.absent("arithmetic.svg");
    // Original 192 process scenarios plus lazy typesetter loading, output
    // aliases and polygon operations, driven through Zig's process/file APIs.
    const expected_checks: usize = 234 + @import("cli/batch.zig").process_count + @import("cli/workers.zig").process_count + @import("cli/exposures.zig").process_count + @import("cli/envelopes.zig").process_count + @import("cli/composition.zig").process_count + @import("cli/imports.zig").process_count + @import("cli/variadic.zig").process_count + @import("cli/scopes.zig").process_count + @import("cli/slices.zig").process_count + @import("cli/mixfix.zig").process_count + @import("cli/assertions.zig").process_count + @import("cli/optimization.zig").process_count +
        @import("cli/path_queries.zig").process_count +
        @import("cli/weave.zig").process_count +
        @as(usize, @intFromBool(try context.exists("CASE-PROBE"))) +
        @as(usize, @intFromBool(try context.exists("unicode-case-probe-é"))) +
        @as(usize, @intFromBool(try context.exists("unicode-normalization-probe-e\u{301}")));
    try std.testing.expectEqual(expected_checks, context.checks);
    std.debug.print("CLI acceptance: {d} processes passed; script/bytecode/parameters/diagnostics/SVG/PDF verified\n", .{context.checks});
}
