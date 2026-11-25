//! Real source -> bytecode -> VM -> geometry/native typography integration.

test {
    _ = @import("language/animation.zig");
    _ = @import("language/animation_snapshots.zig");
    _ = @import("language/constant_propagation.zig");
    _ = @import("language/drawing_blocks.zig");
    _ = @import("language/mixfix.zig");
    _ = @import("language/modules.zig");
    _ = @import("language/paints.zig");
    _ = @import("language/path_construction.zig");
    _ = @import("language/path_operations.zig");
    _ = @import("language/pictures.zig");
    _ = @import("language/runtime.zig");
    _ = @import("language/scoped_imports.zig");
    _ = @import("language/transforms.zig");
    _ = @import("language/typst_blocks.zig");
    _ = @import("language/typst_modules.zig");
    _ = @import("language/typst_reads.zig");
    _ = @import("language/typst_show.zig");
}
