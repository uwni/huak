//! Compilation and editor services; applications own I/O policy and entrypoints.
pub const compiler = @import("language/compiler.zig");
pub const Frontend = @import("tooling/Frontend.zig");
pub const SourceLoader = @import("tooling/SourceLoader.zig");
pub const format = @import("tooling/format.zig");
pub const lsp = @import("tooling/lsp.zig");
pub const position = @import("tooling/position.zig");
pub const TextEdit = @import("tooling/TextEdit.zig");
pub const diagnostics = @import("tooling/diagnostics.zig");
pub const inlay_hints = @import("tooling/inlay_hints.zig");
pub const outputs = @import("tooling/outputs.zig");
pub const definition = @import("tooling/definition.zig");
pub const semantic_tokens = @import("tooling/semantic_tokens.zig");

test {
    _ = format;
    _ = TextEdit;
    _ = lsp;
    _ = position;
    _ = diagnostics;
    _ = inlay_hints;
    _ = outputs;
    _ = definition;
    _ = semantic_tokens;
}
