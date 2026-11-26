//! Writing the result: the pieces, within groups clipped to where they
//! paint, with the source's curves and their new colors.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const DisplayList = @import("../DisplayList.zig");
const style = @import("../style.zig");
const outline = @import("../outline.zig");
const flattening = @import("../path/flatten.zig");
const Style = style.Style;
const transparency = @import("../transparency.zig");
const compositing = @import("paints.zig");
const coverage = @import("coverage.zig");
const Leaf = transparency.Leaf;
const Node = transparency.Node;
const Piece = transparency.Piece;
const narrowed = transparency.narrowed;
const intersectBoxes = transparency.intersectBoxes;
const visibility = @import("visibility.zig");
const Where = visibility.Where;

/// `box` bounds the groups around `nodes`, in world coordinates.
pub fn write(self: anytype, out: *DisplayList, nodes: []const Node, box: ?g.BBox) anyerror!void {
    for (nodes) |node| switch (node) {
        .clip => |group| {
            const inner = narrowed(box, self.leaves.items[group.leaf].bounds) orelse continue;
            const depth = try enter(self, out, group.leaf) orelse continue;
            try write(self, out, group.children, inner);
            for (0..depth) |_| try out.endScope();
        },
        .piece => |part| try paint(self, out, part, box),
    };
}

/// Opens the groups that clip to where `id` paints, and returns how
/// many; null where it paints nothing, which would hide all inside.
fn enter(self: anytype, out: *DisplayList, id: u32) !?usize {
    const shape_ = try clipShape(self, id);
    if (shape_.segments.items.len == 0) return null;
    const depth = try enterClips(self, out, self.leaves.items[id].clip);
    try out.beginScopeView(.{}, &shape_);
    return depth + 1;
}

/// What a group clips with to where `id` paints, within the clips
/// around it, in world coordinates, filled by the nonzero rule.
fn clipShape(self: anytype, id: u32) !Path {
    const leaf = self.leaves.items[id];
    return switch (leaf.component) {
        // A nonzero fill clips with its own curves, closed.
        .fill => if (leaf.draw().style.fill_rule == .nonzero) try closedPath(self, id) else (try coverage.shape(self, id)).*,
        .stroke, .text => (try coverage.shape(self, id)).*,
    };
}

/// `clipShape` traced by lines within the tolerance.
fn traced(self: anytype, id: u32) !*const Path {
    if (self.tracings.get(id)) |known| return known;
    const lines = flattening.flatten(self.gpa, try clipShape(self, id), .{
        .tolerance = self.options.tolerance,
        .length_tolerance = self.options.tolerance,
        .max_segments = outline.max_items,
        .max_depth = 24,
    }) catch |err| return switch (err) {
        error.StrokeWorkLimit => error.GeometryWorkLimit,
        else => err,
    };
    return coverage.store(self, &self.tracings, id, lines);
}

fn enterClips(self: anytype, out: *DisplayList, id: ?u32) !usize {
    const clip = self.clips.items[id orelse return 0];
    const depth = try enterClips(self, out, clip.parent);
    try out.beginScopeView(.{}, &clip.path);
    return depth + 1;
}

fn closedPath(self: anytype, id: u32) !Path {
    if (self.closed_paths.get(id)) |known| return known;
    const leaf = self.leaves.items[id];
    const view = try leaf.picture.geometry().view(self.arena, leaf.draw().path);
    var result = Path.init(self.arena);
    try result.segments.ensureUnusedCapacity(self.arena, view.segments.items.len);
    for (view.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (result.open) try result.close();
            try result.moveTo(leaf.transform.apply(point));
        },
        .line => |point| try result.lineTo(leaf.transform.apply(point)),
        .cubic => |curve| try result.cubicTo(leaf.transform.apply(curve.c1), leaf.transform.apply(curve.c2), leaf.transform.apply(curve.end)),
        .close => try result.close(),
    };
    if (result.open) try result.close();
    try self.closed_paths.put(self.arena, id, result);
    return result;
}

/// `box` bounds the groups around the piece, in world coordinates.
fn paint(self: anytype, out: *DisplayList, part: Piece, box: ?g.BBox) !void {
    const leaf = self.leaves.items[part.geometry];
    // Where it can show, in world coordinates.
    var visible = narrowed(box, leaf.bounds) orelse return;
    if (part.within) |inside| visible = intersectBoxes(visible, self.leaves.items[inside].bounds) orelse return;
    const drawn: ?Drawn = if (leaf.component == .text) text: {
        // Only an unchanged text is painted as itself.
        std.debug.assert(part.expr.* == .leaf and part.expr.leaf == part.geometry);
        break :text null;
    } else try drawing(self, leaf, part, visible) orelse return;
    var depth = try enterClips(self, out, leaf.clip);
    if (part.within) |inside| depth += try enter(self, out, inside) orelse {
        for (0..depth) |_| try out.endScope();
        return;
    };
    if (drawn) |shape_| {
        try out.addPathView(&shape_.path, &shape_.style, leaf.transform);
    } else try out.addLabel(leaf.command.label.reference, leaf.command.label.metrics, leaf.transform);
    for (0..depth) |_| try out.endScope();
}

const Drawn = struct { path: Path, style: Style };

/// The curves and paint of a piece that is not a text, or null where
/// none of it can show within `visible`, a box in world coordinates.
fn drawing(self: anytype, leaf: Leaf, part: Piece, visible: g.BBox) !?Drawn {
    const draw = leaf.draw();
    const view = try leaf.picture.geometry().view(self.arena, draw.path);
    if (part.expr.* == .leaf and part.expr.leaf == part.geometry) return .{ .path = view, .style = switch (leaf.component) {
        .fill => .{ .fill = draw.style.fill, .fill_rule = draw.style.fill_rule },
        .stroke => .{ .pen = draw.style.pen },
        .text => unreachable,
    } };
    const paints = try compositing.varying(self, part.expr);
    const painted: DisplayList.Paint = if (paints.len == 0) .{ .color = compositing.solidColor(self, part.expr) } else varying: {
        // Where it can show, in its own coordinates.
        const own = view.bounds() orelse return error.InvalidPath;
        var where: Where = .{ .cover = if (leaf.transform.inverse()) |inverse| intersectBoxes(own, visible.transformed(inverse)) orelse return null else |_| own };
        if (part.within) |inside| where.within = .{ .lines = try traced(self, inside), .transform = leaf.transform };
        break :varying .{ .gradient = try compositing.composite(self, part.expr, paints, where) orelse return null };
    };
    if (part.fills_clip) {
        // The group clips to the paint's coverage; a box around its
        // curves, in its own coordinates, fills it.
        const tight = (try DisplayList.pathBounds(view.segments.items, if (leaf.component == .stroke) draw.style.pen else null, .{})) orelse return error.InvalidPath;
        // Wider than the curves, so that no edge of the box runs
        // along the clip and anti-aliases with it.
        const box = tight.expanded(0.1 * @max(tight.max.x - tight.min.x, tight.max.y - tight.min.y));
        return .{ .path = try Path.rectangle(self.arena, box.min, box.max.x - box.min.x, box.max.y - box.min.y), .style = .{ .fill = painted } };
    }
    return .{ .path = view, .style = switch (leaf.component) {
        .fill => .{ .fill = painted, .fill_rule = draw.style.fill_rule },
        .stroke => stroke: {
            var pen = draw.style.pen.?;
            pen.paint = painted;
            break :stroke .{ .pen = pen };
        },
        .text => unreachable,
    } };
}
