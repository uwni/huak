//! A sample of a face: its parameters, projection, depth, normal, light and
//! the script's field.
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const Node = @This();
const Shine = space_shading.Shine;
const Vec3 = space_shading.Vec3;

uv: g.Point,
x: f64 = 0,
y: f64 = 0,
depth: f64 = 0,
/// The unit normal of the side shaded; zero where it is undefined.
normal: Vec3 = .{ 0, 0, 0 },
/// n·v, positive on the front sheet.
facing: f64 = 0,
shine: Shine = .{ .diffuse = 0, .glint = 0 },
/// The script's field, once sampled.
value: f64 = 0,
/// The glint before lighting gates it.
raw: f64 = -1,
/// On the contour or on a parameter bound of the face.
place: u8 = 0,
/// Without a normal: the facing comes from points nearby, and the light
/// of a patch from a point toward its center.
singular: bool = false,

/// Node places: the contour, and the four parameter bounds of a face that is
/// not periodic in that direction. Patch sides along one place get a skirt.
pub const on_contour: u8 = 1;

pub const on_bounds: u8 = 2 | 4 | 8 | 16;
