//! What the tones fixture draws, read from its SVG.
//!
//! `toned` colors a sphere under the usual page light in four tones. The
//! part turned away and the first band share a tone and touch, so they must
//! come out as one path: four fills, one of each tone.
//!
//! `flat` colors a sphere lit almost from the reader in the average of its
//! tones. The light makes the angle whose cosine is `out` with the line of
//! sight. Where a surface faces it by at least a cut `c` not below the sine
//! of that angle, the sphere shows an ellipse of area pi (1 - c^2) out on
//! its unit disk, so the tones take the shares below.
//!
//! An ink at half opacity is drawn both ways over a black line. Flattened,
//! every fill is the tone halfway to white and the line shows in pieces over
//! the sphere, each the tone halfway to black. As a layer, the fills are the
//! tones themselves inside one group at half opacity. Either way the whole
//! line lies under the sphere in black.
const std = @import("std");

const cuts = [_]f64{ 0, 0.15, 0.6, 0.93 };
const levels = [_]f64{ -0.30, 0.06, 0.40, 0.66 };
const teal: [3]f64 = .{ 0.16, 0.61, 0.58 };
const blue: [3]f64 = .{ 0.33, 0.50, 0.80 };
const wine: [3]f64 = .{ 0.70, 0.25, 0.30 };
const plum: [3]f64 = .{ 0.45, 0.30, 0.65 };
/// The light of the second sphere on the page's axes, before it is scaled
/// to a unit.
const near: [3]f64 = .{ -0.1, 0.1, 0.99 };

fn tone(ink: [3]f64, level: f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (&out, ink) |*o, c| o.* = if (level < 0) c * (1 + level) else c + (1 - c) * level;
    return out;
}

/// `color` halfway to a gray: 1 for white paper, 0 for a black line.
fn halfway(color: [3]f64, gray: f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (&out, color) |*o, c| o.* = 0.5 * c + 0.5 * gray;
    return out;
}

/// How many paints of `kind` ("fill" or "stroke") in `svg` are within one
/// step of `color` on every channel.
fn count(svg: []const u8, comptime kind: []const u8, color: [3]f64) !usize {
    const key = kind ++ "=\"#";
    var found: usize = 0;
    var rest = svg;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        rest = rest[at + key.len ..];
        if (rest.len < 7 or rest[6] != '"') continue;
        var close = true;
        for (color, 0..) |c, k| {
            const channel: f64 = @floatFromInt(try std.fmt.parseInt(u8, rest[2 * k ..][0..2], 16));
            if (@abs(channel - 255 * c) > 1) close = false;
        }
        if (close) found += 1;
    }
    return found;
}

fn once(svg: []const u8, comptime what: []const u8, color: [3]f64) !void {
    const found = try count(svg, "fill", color);
    if (found == 1) return;
    std.debug.print(what ++ " ({d:.4}, {d:.4}, {d:.4}): {d} fills, expected one\n", .{ color[0], color[1], color[2], found });
    return error.UnexpectedFills;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) {
        std.debug.print("usage: {s} TONES_SVG\n", .{args[0]});
        return error.InvalidArguments;
    }
    const svg = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(64 * 1024 * 1024));

    for (levels) |level| try once(svg, "tone", tone(teal, level));

    const out = near[2] / @sqrt(near[0] * near[0] + near[1] * near[1] + near[2] * near[2]);
    std.debug.assert(cuts[1] * cuts[1] >= 1 - out * out);
    var mean: [3]f64 = @splat(0);
    var whole: f64 = 0;
    for (levels, 0..) |level, k| {
        const from = if (k == 0) 1 / out else 1 - cuts[k] * cuts[k];
        const to = if (k + 1 == cuts.len) 0 else 1 - cuts[k + 1] * cuts[k + 1];
        const share = out * (from - to);
        whole += share;
        for (&mean, tone(blue, level)) |*m, c| m.* += share * c;
    }
    std.debug.assert(@abs(whole - 1) < 1e-12);
    try once(svg, "average", mean);

    // Flattened: no fill anywhere is translucent, and the line behind the
    // sphere shows in at least two tones.
    var rest = svg;
    while (std.mem.indexOf(u8, rest, "fill=\"#")) |at| {
        rest = rest[at + "fill=\"#".len ..];
        // Typst writes an opacity as a fourth pair of digits.
        if (rest.len > 8 and rest[8] == '"') return error.TranslucentFill;
    }
    if (std.mem.indexOf(u8, svg, "fill-opacity") != null) return error.TranslucentFill;
    var pieces: usize = 0;
    for (levels) |level| {
        try once(svg, "tone over paper", halfway(tone(wine, level), 1));
        pieces += try count(svg, "stroke", halfway(tone(wine, level), 0));
    }
    if (pieces < 2) {
        std.debug.print("{d} pieces of the line in mixed colors, expected at least two\n", .{pieces});
        return error.LineNotMixed;
    }

    // As a layer: the tones as they are, one group with the opacity and its
    // rule. Both lines are drawn in black under their spheres.
    for (levels) |level| try once(svg, "tone in the layer", tone(plum, level));
    if (std.mem.count(u8, svg, " data-typst-label=\"huak-opacity-0.5\"") != 1) return error.LayerNotGrouped;
    if (std.mem.indexOf(u8, svg, "[data-typst-label=\"huak-opacity-0.5\"]{opacity:0.5}") == null) return error.LayerRuleMissing;
    if (try count(svg, "stroke", .{ 0, 0, 0 }) != 2) return error.LinesNotUnderSpheres;
}
