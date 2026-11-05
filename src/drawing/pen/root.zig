//! Convex, independently transformed pen geometry. Nib coordinates use the
//! same physical unit as the path. The default circle has diameter one.
pub const Nib = @import("nib.zig").Nib;
pub const OwnedNib = @import("nib.zig").OwnedNib;
pub const makePen = @import("nib.zig").makePen;
pub const StrokeOptions = @import("outline.zig").Options;
pub const strokeOutline = @import("outline.zig").strokeOutline;
pub const EnvelopeOptions = @import("envelope.zig").Options;
pub const envelope = @import("envelope.zig").envelope;
pub const dashed = @import("dash.zig").dashed;
pub const sections = @import("sections.zig");
pub const profileOutline = @import("../region/root.zig").profileStroke;
pub const Cap = @import("stroke.zig").Cap;
pub const Join = @import("stroke.zig").Join;

test {
    _ = @import("nib.zig");
    _ = @import("outline.zig");
    _ = @import("dash.zig");
    _ = @import("sections.zig");
}
