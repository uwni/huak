//! DisplayList scenes through the real native backend, exported as SVG and PDF: mesh PDFs, gradients, layers, pens, labels and backend limits.

test {
    _ = @import("drawing/mesh_pdf.zig");
    _ = @import("drawing/gradients.zig");
    _ = @import("drawing/layers.zig");
    _ = @import("drawing/pens.zig");
    _ = @import("drawing/labels.zig");
    _ = @import("drawing/backend.zig");
}
