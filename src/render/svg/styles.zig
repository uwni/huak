//! Style rules huak adds to an SVG that Typst exported. Typst writes the
//! elements; groups it labeled pick up here what its scene cannot say: that
//! a mesh's triangles are drawn without antialiasing (`mesh.zig`), and that a
//! layer is blended at its opacity.
const std = @import("std");

/// Opacities are kept to this many steps, so that layers of one opacity
/// share a label and a rule.
const steps = 10000;

fn rounded(opacity: f64) f64 {
    return @round(opacity * steps) / steps;
}

/// Native scene tag of a group shown as one layer at `opacity`. Typst writes
/// it as `data-typst-label`. The name states the rule, so equal names in
/// documents inlined into one page mean equal rules.
pub fn layerLabel(buffer: *[32]u8, opacity: f64) []const u8 {
    return std.mem.print(buffer, "huak-opacity-{d}", .{rounded(opacity)}) catch unreachable;
}

/// The rule that blends groups labeled for `opacity` as one layer each: the
/// `opacity` property composites an element's content before blending it.
pub fn layerRule(rules: *std.ArrayList(u8), allocator: std.mem.Allocator, opacity: f64) !void {
    var buffer: [32]u8 = undefined;
    var selector: [64]u8 = undefined;
    const target = std.mem.print(&selector, "[data-typst-label=\"{s}\"]", .{layerLabel(&buffer, opacity)}) catch unreachable;
    // One rule for each label, however many layers share it.
    if (std.mem.find(u8, rules.items, target) != null) return;
    try rules.print(allocator, "{s}{{opacity:{d}}}", .{ target, rounded(opacity) });
}

/// Appends `rules` as one stylesheet before the root element's closing tag.
/// The caller owns the result.
pub fn add(allocator: std.mem.Allocator, svg: []const u8, rules: []const u8) ![]u8 {
    const close = std.mem.findLast(u8, svg, "</svg>") orelse return error.UnsupportedSvg;
    return std.mem.concat(allocator, u8, &.{ svg[0..close], "<style>", rules, "</style>", svg[close..] });
}

const t = std.testing;

test "the stylesheet ends the root element" {
    const result = try add(t.allocator, "<svg><g/></svg>\n", "g{opacity:0.5}");
    defer t.allocator.free(result);
    try t.expectEqualStrings("<svg><g/><style>g{opacity:0.5}</style></svg>\n", result);
    try t.expectError(error.UnsupportedSvg, add(t.allocator, "<g/>", ""));
}

test "layers of one opacity share a label and a rule" {
    var rules: std.ArrayList(u8) = .empty;
    defer rules.deinit(t.allocator);
    var buffer: [32]u8 = undefined;
    try t.expectEqualStrings("huak-opacity-0.82", layerLabel(&buffer, 0.82));
    try t.expectEqualStrings("huak-opacity-0.3333", layerLabel(&buffer, 1.0 / 3.0));
    try layerRule(&rules, t.allocator, 0.82);
    try layerRule(&rules, t.allocator, 0.8);
    try layerRule(&rules, t.allocator, 0.82000001);
    try layerRule(&rules, t.allocator, 0.8);
    try t.expectEqualStrings("[data-typst-label=\"huak-opacity-0.82\"]{opacity:0.82}[data-typst-label=\"huak-opacity-0.8\"]{opacity:0.8}", rules.items);
}
