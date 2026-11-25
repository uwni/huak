//! Migrated region contracts. Numeric/error/allocation expectations are kept
//! from the former polygon adapter; only flattening-specific assertions change.

test {
    _ = @import("operations/booleans.zig");
    _ = @import("operations/outlines.zig");
    _ = @import("operations/clipping.zig");
    _ = @import("operations/limits.zig");
}
