//! Curve-preserving records used only by the independent region test oracle.
//! Verbs: move=0, line=1, quad=2, conic=3, cubic=4, close=5.
pub const Element = struct { verb: u32, data: [6]f64 = @splat(0) };
