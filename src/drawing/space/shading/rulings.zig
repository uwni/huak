//! How a cone's rulings project, and halve until a fan is within its error bound.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const Info = space_shading.Info;
const angular_precision = space_shading.angular_precision;
const Error = space_shading.Error;

/// How often an arc of rulings may halve before a fan gives way to patches:
/// where the view runs along a ruling no arc is short enough.
const max_halvings = 40;

/// What rounding may leave of a difference, as a share of its terms.
pub const rounding = 1e-12;

/// A quantity a cos u + b sin u + c along a cone's rulings u.
pub const Wave = struct {
    a: f64,
    b: f64,
    c: f64,

    /// From the quantity on the rulings 0, a quarter turn and half a turn.
    pub fn through(first: f64, second: f64, third: f64) Wave {
        const c = (first + third) / 2;
        return .{ .a = (first - third) / 2, .b = second - c, .c = c };
    }

    pub fn at(self: Wave, u: f64) f64 {
        return self.a * @cos(u) + self.b * @sin(u) + self.c;
    }

    /// The rulings where the quantity is positive, null when there are none.
    pub fn positive(self: Wave) ?Arc {
        const swing = std.math.hypot(self.a, self.b);
        if (self.c <= -swing) return null;
        const middle = if (swing > 0) std.math.atan2(self.b, self.a) else 0;
        return .{ .middle = middle, .half = if (self.c >= swing) std.math.pi else std.math.acos(-self.c / swing) };
    }
};

/// The rulings within `half` of `middle`; all of them at half a turn.
const Arc = struct {
    middle: f64,
    half: f64,

    /// The least range holding the arc's parts within `range`, which spans
    /// at most a turn.
    pub fn hull(self: Arc, range: [2]f64) ?[2]f64 {
        if (self.half >= std.math.pi) return range;
        var found: ?[2]f64 = null;
        var turn: f64 = -2;
        while (turn <= 2) : (turn += 1) {
            const low = @max(range[0], self.middle - self.half + 2 * std.math.pi * turn);
            const high = @min(range[1], self.middle + self.half + 2 * std.math.pi * turn);
            if (!(high > low)) continue;
            found = if (found) |held| .{ @min(held[0], low), @max(held[1], high) } else .{ low, high };
        }
        return found;
    }
};

/// The rulings of a face that face the viewer, null when none do or they
/// make several arcs.
pub fn frontRulings(facing: Wave, info: Info) ?[2]f64 {
    const front = facing.positive() orelse return null;
    const whole = info.u_period > 0 and info.u[1] - info.u[0] >= info.u_period - angular_precision;
    if (front.half >= std.math.pi) return if (whole) .{ front.middle - std.math.pi, front.middle + std.math.pi } else info.u;
    const seen: [2]f64 = .{ front.middle - front.half, front.middle + front.half };
    if (whole) return seen;
    var found: ?[2]f64 = null;
    var turn: f64 = -2;
    while (turn <= 2) : (turn += 1) {
        const low = @max(seen[0], info.u[0] + 2 * std.math.pi * turn);
        const high = @min(seen[1], info.u[1] + 2 * std.math.pi * turn);
        if (!(high > low)) continue;
        if (found != null) return null;
        found = .{ low, high };
    }
    return found;
}

/// How a cone's rulings project: ruling u runs from the apex's projection
/// to q cos u + r sin u + p beyond it.
///
/// Lift u to c(u) = (cos u, sin u, 1). The far ends are F c(u) for the 2 x 3
/// matrix F = [q r p], whose kernel k = (r x p, p x q, q x r) spans, and a
/// light a cos u + b sin u + c is l · c(u). The ray through ruling u meets
/// the chord of rulings m - h and m + h where t c(u) = (1 - w) c(m - h) +
/// w c(m + h) + s k, and the fan there is l · ((1 - w) c(m - h) +
/// w c(m + h)) = t l · c(u) - s l · k. The third coordinates give t = 1 +
/// s k3, and the product with c(m - h) x c(m + h) = 2 sin h (-cos m, -sin m,
/// cos h) gives s = -(cos(u - m) - cos h) / G(u - m), where G(d) = k3 cos d -
/// k1 cos m - k2 sin m. So the light less the fan is s N(u), where N(u) =
/// l · k - k3 l · c(u) = a (k1 - k3 cos u) + b (k2 - k3 sin u).
pub const Spokes = struct {
    q: g.Point,
    r: g.Point,
    p: g.Point,
    k: [3]f64,

    pub fn init(q: g.Point, r: g.Point, p: g.Point) Spokes {
        return .{ .q = q, .r = r, .p = p, .k = .{ r.cross(p), p.cross(q), q.cross(r) } };
    }

    fn ray(self: Spokes, u: f64) g.Point {
        return self.q.scale(@cos(u)).add(self.r.scale(@sin(u))).add(self.p);
    }

    /// At least the largest difference between `wave` and the fan through
    /// the rulings `from` and `to`, on the rulings between them: the largest
    /// 1 - cos h and |N| over the least |G|. Infinite where a ray between
    /// them may run along their chord: where the least |G| is no more than
    /// the rounding of its terms.
    fn bound(self: Spokes, wave: Wave, from: f64, to: f64) f64 {
        const h = (to - from) / 2;
        const m = (from + to) / 2;
        const sagitta = 1 - @cos(h);
        const least = @abs(self.k[2] - self.k[0] * @cos(m) - self.k[1] * @sin(m)) - @abs(self.k[2]) * sagitta;
        if (!(least > rounding * (@abs(self.k[0]) + @abs(self.k[1]) + @abs(self.k[2])))) return std.math.inf(f64);
        const most = @abs(wave.a * (self.k[0] - self.k[2] * @cos(m)) + wave.b * (self.k[1] - self.k[2] * @sin(m))) + @abs(self.k[2]) * std.math.hypot(wave.a, wave.b) * 2 * @sin(h / 2);
        return sagitta * most / least;
    }

    /// Appends rulings after `range[0]` up to `range[1]`, such that between
    /// neighbours the fan stays within `target` of `wave` and turns at most
    /// a quarter turn. False where `max_halvings` of an eighth of a turn do
    /// not get there; more than `cap` rulings report ShadingLimit.
    pub fn divide(self: Spokes, allocator: std.mem.Allocator, out: *std.ArrayList(f64), wave: Wave, range: [2]f64, target: f64, cap: usize) Error!bool {
        const pieces = @max(1, @ceil((range[1] - range[0]) / (std.math.pi / 4.0)));
        const count: usize = @intFromFloat(pieces);
        var from = range[0];
        for (1..count + 1) |piece| {
            const to = if (piece == count) range[1] else range[0] + (range[1] - range[0]) * @as(f64, @floatFromInt(piece)) / pieces;
            if (!try self.halve(allocator, out, wave, from, to, target, cap, max_halvings)) return false;
            from = to;
        }
        return true;
    }

    fn halve(self: Spokes, allocator: std.mem.Allocator, out: *std.ArrayList(f64), wave: Wave, from: f64, to: f64, target: f64, cap: usize, left: usize) Error!bool {
        const first = self.ray(from);
        const last = self.ray(to);
        const turn = @abs(std.math.atan2(first.cross(last), first.dot(last)));
        if (!(self.bound(wave, from, to) <= target) or turn > std.math.pi / 2.0) {
            if (left == 0) return false;
            const middle = (from + to) / 2;
            return try self.halve(allocator, out, wave, from, middle, target, cap, left - 1) and
                try self.halve(allocator, out, wave, middle, to, target, cap, left - 1);
        }
        if (out.items.len >= cap) return error.ShadingLimit;
        try out.append(allocator, to);
        return true;
    }
};
