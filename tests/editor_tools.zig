//! Real standalone formatter and stdio language-server acceptance.

test {
    _ = @import("editor_tools/formatter.zig");
    _ = @import("editor_tools/documents.zig");
    _ = @import("editor_tools/shared_services.zig");
    _ = @import("editor_tools/symbols.zig");
    _ = @import("editor_tools/decorations.zig");
    _ = @import("editor_tools/lifecycle.zig");
    _ = @import("editor_tools/outputs.zig");
    _ = @import("editor_tools/definitions.zig");
}
