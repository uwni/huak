//! What the backend returns, as checked slices: arcs, cells, regions and rows, and the validators that check every index in them.
const c = @import("space_c");
const g = @import("../../geometry.zig");
const Model = @import("../Model.zig");
const View = Model.View;
const Error = Model.Error;

pub fn indices(self: *const View, list: c.HuakIndices) Error![]const usize {
    if (list.count != 0 and list.items == null) return self.model.rejected();
    return items(usize, list.items, list.count);
}

pub fn table(self: *const View, comptime T: type, expected: usize, offsets: [*c]const usize, values: [*c]const T, count: usize) Error!Rows(T) {
    if (count != expected or offsets == null) return self.model.rejected();
    const limits = offsets[0 .. count + 1];
    if (limits[0] != 0) return self.model.rejected();
    for (limits[0..count], limits[1..]) |start, end| if (start > end) return self.model.rejected();
    if (limits[count] != 0 and values == null) return self.model.rejected();
    return .{ .offsets = limits, .values = items(T, values, limits[count]) };
}

pub fn commands(self: *const View, expected: usize, paths: c.HuakPaths) Error!Rows(c.HuakPathCommand) {
    const result = try table(self, c.HuakPathCommand, expected, paths.offsets, paths.commands, paths.count);
    for (result.values) |command| switch (command.op) {
        c.HUAK_MOVE, c.HUAK_LINE, c.HUAK_BEZIER, c.HUAK_CLOSE => {},
        else => return self.model.rejected(),
    };
    return result;
}

fn boxOf(box: c.HuakBox) ?g.BBox {
    if (box.empty != 0) return null;
    return .{ .min = .{ .x = box.x0, .y = box.y0 }, .max = .{ .x = box.x1, .y = box.y1 } };
}

/// The arcs of an arrangement, with the images along each:
/// origins[arc.first_origin..][0..arc.origin_count].
pub const Arcs = struct {
    arcs: []const c.HuakArc,
    origins: []const c.HuakArcOrigin,

    pub fn along(self: Arcs, k: usize) []const c.HuakArcOrigin {
        return self.origins[self.arcs[k].first_origin..][0..self.arcs[k].origin_count];
    }
};

/// The cells of an arrangement with the layers over each, and the cells on
/// the left and on the right of each arc.
pub const Cells = struct {
    layers: Rows(c.HuakLayer),
    left: []const usize,
    right: []const usize,
};

/// The connected regions of sets of arcs: set k's are regions sets[k] ..
/// sets[k + 1], each with its outline, bounds and (when requested) moments.
pub const Regions = struct {
    sets: []const usize,
    outlines: Rows(c.HuakPathCommand),
    bounds: []const c.HuakBox,
    moments: []const c.HuakMoments,

    /// A region's bounds with its tolerance; null for an empty one.
    pub fn bound(self: Regions, region: usize) ?g.BBox {
        return boxOf(self.bounds[region]);
    }
};

/// Lists laid out one after another: list k is values[offsets[k]..offsets[k + 1]].
pub fn Rows(comptime T: type) type {
    return struct {
        offsets: []const usize,
        values: []const T,

        pub fn row(self: @This(), k: usize) []const T {
            return self.values[self.offsets[k]..self.offsets[k + 1]];
        }
    };
}

pub fn items(comptime T: type, pointer: [*c]const T, count: usize) []const T {
    return if (count == 0) &.{} else pointer[0..count];
}
