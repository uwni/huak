//! Bundled Huak source recipes use the same bytecode and native host as user code.

test {
    _ = @import("standard_library/modules.zig");
    _ = @import("standard_library/mixfix.zig");
    _ = @import("standard_library/brushes.zig");
    _ = @import("standard_library/pen_motion.zig");
    _ = @import("standard_library/cut.zig");
    _ = @import("standard_library/cut_outlines.zig");
    _ = @import("standard_library/objects.zig");
    _ = @import("standard_library/defaults.zig");
}
