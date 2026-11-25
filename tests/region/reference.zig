//! Geometry contracts migrated from the former native PathOps reference tests.
//! The original inputs and absolute area/probe thresholds are unchanged. All
//! calls use Huak's public owned Path and region API, without a C ABI mirror.

test {
    _ = @import("reference/fill_rules.zig");
    _ = @import("reference/containment.zig");
    _ = @import("reference/exact_geometry.zig");
}
