//! Deferred modelling operations. Each node refers only to previously created
//! geometry; constructing a model needs neither a camera nor a loaded kernel.
const types = @import("../types.zig");
pub const Kind = enum {
    segment,
    cubic,
    polyline,
    polygon,
    circle,
    ellipse,
    arc,
    joined,
    reverse,
    closed,
    sphere,
    cylinder,
    cone,
    torus,
    profile,
    face,
    extrude,
    revolve,
    surface_curve,
    transformed,
    sweep,
    loft,
    solid_loft,
    fuse,
    common,
    cut,
};
pub const Node = struct { kind: Kind, arguments: []const types.Value };
