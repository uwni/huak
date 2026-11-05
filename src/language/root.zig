//! Script compilation and native drawing execution.
pub const compiler = @import("compiler.zig");
pub const bytecode = @import("bytecode.zig");
pub const types = @import("types.zig");
pub const Machine = @import("Machine.zig");
pub const Runtime = @import("Runtime.zig");
pub const OutputBatch = @import("OutputBatch.zig");
pub const tasks = @import("tasks.zig");

test {
    _ = compiler;
    _ = Machine;
    _ = Runtime;
    _ = tasks;
    _ = @import("optimizer.zig");
}
