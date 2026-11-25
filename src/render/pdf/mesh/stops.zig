//! How the page paints the stops over the field: the stop plan, the base fill, color ramps, opacity and coverage masks, and their transfer functions.
const std = @import("std");
const style = @import("../../../drawing/style.zig");
const Gradient = style.Gradient;
const Color = style.Color;
const Patches = Gradient.Patches;
const color_patches = @import("../../../drawing/color_patches.zig");
const syntax = @import("../syntax.zig");
const Segment = syntax.Segment;
const real = syntax.real;
/// Corners in record order, p00, p03, p33, p30: the order in which color
/// patches give their colors.
const corner_order = color_patches.corner_index;
const mesh = @import("../mesh.zig");
const Unit = mesh.Unit;

/// How the page paints the stops over the field's range. The colors build
/// up in layers: a fill with the base stop's color, then for each ramp of
/// `Ramps`, a fill with the color of its upper stop whose weight rises from
/// 0 at its lower stop's level to 1 at its own. Laid in order, these are
/// exactly the stops' linear interpolation. Stops at or below the low end
/// fold into the base.
///
/// Outside the patches every mask reads gray 0, the low end of the range.
/// Unless the opacity there is zero, a coverage mask, the alpha of the mesh
/// itself, keeps the paint to the patches.
pub const Plan = struct {
    stops: Gradient.Stops,
    /// The field's range: gray 0 to 1 on the mesh.
    range: [2]f64,
    /// The stop whose color the base fill has.
    base: usize,
    /// How many ramps lay a fill over the base.
    layers: usize,
    opacity: union(enum) { constant: f64, varying },
    coverage: bool,

    pub fn of(stops: Gradient.Stops, range: [2]f64) Plan {
        var plan: Plan = .{ .stops = stops, .range = range, .base = 0, .layers = 0, .opacity = .varying, .coverage = false };
        for (stops.levels, 0..) |level, index| {
            if (level <= range[0]) plan.base = index;
        }
        var each = plan.ramps();
        while (each.next()) |_| plan.layers += 1;
        const low = stops.at(range[0]).a;
        var constant = stops.at(range[1]).a == low;
        for (stops.levels, stops.colors) |level, color| {
            if (level > range[0] and level < range[1] and color.a != low) constant = false;
        }
        if (constant) plan.opacity = .{ .constant = low };
        plan.coverage = low > 0;
        return plan;
    }

    pub fn ramps(self: *const Plan) Ramps {
        return .{ .stops = self.stops, .high = self.range[1], .from = self.base };
    }
};

/// The color layers, as pairs of stops: each ramp runs from one stop to a
/// later one, and the next ramp starts where it ends. A ramp passes over the
/// stops whose colors lie on its straight line, up to rounding, since they
/// change nothing; it adds no layer when its ends have the same color, and
/// ramps starting at or above the field's high end add nothing.
const Ramps = struct {
    stops: Gradient.Stops,
    high: f64,
    from: usize,

    pub fn next(self: *Ramps) ?[2]usize {
        const levels = self.stops.levels;
        const colors = self.stops.colors;
        while (self.from + 1 < levels.len and levels[self.from] < self.high) {
            const from = self.from;
            var to = from + 1;
            while (to + 1 < levels.len and onLine(self.stops, from, to + 1)) to += 1;
            self.from = to;
            const a = colors[from];
            const b = colors[to];
            if (a.r != b.r or a.g != b.g or a.b != b.b) return .{ from, to };
        }
        return null;
    }
};

/// Whether every stop strictly between `from` and `to` has the color that
/// linear interpolation between them gives, to well below the precision the
/// page writes.
fn onLine(stops: Gradient.Stops, from: usize, to: usize) bool {
    const levels = stops.levels;
    const a = stops.colors[from];
    const b = stops.colors[to];
    for (from + 1..to) |index| {
        const s = (levels[index] - levels[from]) / (levels[to] - levels[from]);
        const c = stops.colors[index];
        const off = @max(@abs(c.r - (a.r + s * (b.r - a.r))), @abs(c.g - (a.g + s * (b.g - a.g))), @abs(c.b - (a.b + s * (b.b - a.b))));
        if (!(off <= 1e-12)) return false;
    }
    return true;
}

/// Clips to the exact path, then paints the plan through its masks.
pub fn writeContent(w: *std.Io.Writer, clip: []const Segment, unit: Unit, evenodd: bool, plan: Plan) !void {
    try syntax.path(w, clip, unit);
    try w.writeAll(if (evenodd) "\nW*\nn" else "\nW\nn");
    if (plan.coverage) {
        try w.writeAll("\n/Coverage gs");
        // A soft mask applies to a group as a whole; inside it, the
        // opacity mask can take over the state.
        if (plan.opacity == .varying) return w.writeAll("\n/Masked Do");
    } else try w.writeAll("\n/Opacity gs");
    try writePaint(w, plan);
}

/// The colors: the form of the layers, or the base fill alone.
pub fn writePaint(w: *std.Io.Writer, plan: Plan) !void {
    if (plan.layers != 0) return w.writeAll("\n/Color Do");
    try w.writeByte('\n');
    try fill(w, plan.stops.colors[plan.base]);
}

/// Fills the page square with one color.
pub fn fill(w: *std.Io.Writer, color: Color) !void {
    for ([3]f64{ color.r, color.g, color.b }) |component| {
        try real(w, component);
        try w.writeByte(' ');
    }
    try w.writeAll("rg\n0 0 1 1 re\nf");
}

/// The alpha of the mesh's own group, 1 on the patches and 0 elsewhere,
/// with a constant opacity.
pub fn writeCoverage(w: *std.Io.Writer, plan: Plan) !void {
    try w.writeAll("/Coverage<</SMask<</Type/Mask/S/Alpha/G 6 0 R>>");
    switch (plan.opacity) {
        .constant => |opacity| if (opacity != 1) {
            try w.writeAll("/ca ");
            try real(w, opacity);
        },
        .varying => {},
    }
    try w.writeAll(">>");
}

/// The stops' opacity: a luminosity mask of the mesh when it varies.
pub fn writeOpacity(w: *std.Io.Writer, plan: Plan) !void {
    try w.writeAll("/Opacity<<");
    switch (plan.opacity) {
        .constant => |opacity| {
            try w.writeAll("/ca ");
            try real(w, opacity);
        },
        .varying => {
            try w.writeAll("/SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR");
            try writeTransfer(w, .{ .opacity = plan.stops }, plan.range);
            try w.writeAll(">>");
        },
    }
    try w.writeAll(">>");
}

/// The field's range over the corners, which bound the bilinear field the
/// mesh interpolates; never empty.
pub fn valueRange(patches: Patches) [2]f64 {
    var low: f64 = std.math.inf(f64);
    var high: f64 = -std.math.inf(f64);
    for (patches.values) |field| for (corner_order) |index| {
        low = @min(low, field[index]);
        high = @max(high, field[index]);
    };
    if (!(high > low)) high = low + 1;
    return .{ low, high };
}

/// A function of the field through values at levels, linear between them
/// and flat beyond: the stops' opacity, or a layer's weight, which rises
/// from 0 at the first level to 1 at the second.
const Profile = union(enum) {
    opacity: Gradient.Stops,
    ramp: [2]f64,

    fn len(self: Profile) usize {
        return switch (self) {
            .opacity => |stops| stops.levels.len,
            .ramp => 2,
        };
    }

    fn level(self: Profile, index: usize) f64 {
        return switch (self) {
            .opacity => |stops| stops.levels[index],
            .ramp => |levels| levels[index],
        };
    }

    fn value(self: Profile, index: usize) f64 {
        return switch (self) {
            .opacity => |stops| stops.colors[index].a,
            .ramp => @floatFromInt(index),
        };
    }

    fn at(self: Profile, field: f64) f64 {
        return switch (self) {
            .opacity => |stops| stops.at(field).a,
            .ramp => |levels| std.math.clamp((field - levels[0]) / (levels[1] - levels[0]), 0, 1),
        };
    }
};

/// A knot of a transfer function: gray level `x`, as written, and value.
const Knot = struct { x: f32, y: f64 };

/// The pieces of a profile on the mask's gray scale, from the field's range
/// onto [0, 1], between knots at both ends and at every level strictly
/// inside. Knots that coincide in single precision bound no piece; the value
/// jumps there.
const Pieces = struct {
    profile: Profile,
    range: [2]f64,
    /// The next knot: 0 is the low end, 1 + i level i, 1 + len the high end.
    index: usize = 0,
    last: ?Knot = null,

    fn knot(self: *Pieces) ?Knot {
        const count = self.profile.len();
        while (self.index <= count + 1) {
            const index = self.index;
            self.index += 1;
            if (index == 0) return .{ .x = 0, .y = self.profile.at(self.range[0]) };
            if (index == count + 1) return .{ .x = 1, .y = self.profile.at(self.range[1]) };
            const level = self.profile.level(index - 1);
            if (!(level > self.range[0] and level < self.range[1])) continue;
            return .{ .x = @floatCast((level - self.range[0]) / (self.range[1] - self.range[0])), .y = self.profile.value(index - 1) };
        }
        return null;
    }

    fn next(self: *Pieces) ?[2]Knot {
        while (self.knot()) |current| {
            const previous = self.last;
            self.last = current;
            if (previous) |start| if (start.x < current.x) return .{ start, current };
        }
        return null;
    }
};

/// The profile as a soft mask's transfer function: a stitching (type 3)
/// function of linear (type 2) pieces over the gray levels.
pub fn writeTransfer(w: *std.Io.Writer, profile: Profile, range: [2]f64) !void {
    try w.writeAll("<</FunctionType 3/Domain[0 1]/Functions[");
    var pieces: Pieces = .{ .profile = profile, .range = range };
    var count: usize = 0;
    while (pieces.next()) |piece| : (count += 1) {
        try w.writeAll("<</FunctionType 2/Domain[0 1]/C0[");
        try real(w, piece[0].y);
        try w.writeAll("]/C1[");
        try real(w, piece[1].y);
        try w.writeAll("]/N 1>>");
    }
    // Every piece after the first starts at a bound.
    try w.writeAll("]/Bounds[");
    pieces = .{ .profile = profile, .range = range };
    var index: usize = 0;
    while (pieces.next()) |piece| : (index += 1) {
        if (index == 0) continue;
        if (index != 1) try w.writeByte(' ');
        try real(w, piece[0].x);
    }
    try w.writeAll("]/Encode[");
    for (0..count) |k| try w.writeAll(if (k == 0) "0 1" else " 0 1");
    try w.writeAll("]>>");
}
