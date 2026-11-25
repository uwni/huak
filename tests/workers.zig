//! Automatic drawing-task execution through real native typography and export.

test {
    _ = @import("workers/scheduling.zig");
    _ = @import("workers/shared_inputs.zig");
    _ = @import("workers/typography.zig");
    _ = @import("workers/host_effects.zig");
    _ = @import("workers/failures.zig");
    _ = @import("workers/allocation_failures.zig");
}
