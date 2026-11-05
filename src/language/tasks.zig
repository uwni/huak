//! Automatic construction tasks. Syntax and bytecode stay synchronous; the
//! planner and executor supply dependency-aware workers behind ordinary calls.
pub const Executor = @import("tasks/Executor.zig");
pub const Stats = @import("tasks/Executor.zig").Stats;

test {
    _ = @import("tasks/effects.zig");
    _ = @import("tasks/plan.zig");
}
