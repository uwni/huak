//! Regions: what each paint, clip and unit covers, in world coordinates,
//! computed when first needed and kept by the flattener.
const std = @import("std");
const Path = @import("../path/Path.zig");
const DisplayList = @import("../DisplayList.zig");
const style = @import("../style.zig");
const regions = @import("../region/root.zig");
const Style = style.Style;
const transparency = @import("../transparency.zig");
const Unit = transparency.Unit;

pub fn combine(self: anytype, a: Path, b: Path, operation: regions.Operation) !Path {
    return regions.combine(self.gpa, a, b, operation, .{ .tolerance = self.options.tolerance });
}

pub fn store(self: anytype, table: *std.AutoHashMapUnmanaged(u32, *Path), key: u32, value: Path) !*const Path {
    var path = value;
    errdefer path.deinit();
    const owned = try self.gpa.create(Path);
    errdefer self.gpa.destroy(owned);
    owned.* = path;
    try table.put(self.gpa, key, owned);
    return owned;
}

/// The region a paint covers by itself, in world coordinates.
pub fn shape(self: anytype, id: u32) anyerror!*const Path {
    if (self.shapes.get(id)) |known| return known;
    const leaf = self.leaves.items[id];
    const result = switch (leaf.component) {
        .text => text: {
            const glyphs = try self.glyphsOf(id);
            var union_ = Path.init(self.gpa);
            errdefer union_.deinit();
            for (glyphs) |glyph| try union_.append((try shape(self, glyph)).*);
            break :text union_;
        },
        .fill, .stroke => single: {
            const draw = leaf.draw();
            const view = try leaf.picture.geometry().view(self.arena, draw.path);
            var alone = DisplayList.init(self.gpa);
            defer alone.deinit();
            const ink: Style = if (leaf.component == .fill)
                .{ .fill = .black, .fill_rule = draw.style.fill_rule }
            else stroke: {
                var pen = draw.style.pen.?;
                pen.paint = .black;
                break :stroke .{ .pen = pen };
            };
            try alone.addPathView(&view, &ink, leaf.transform);
            break :single try regions.coverage.extract(self.gpa, &alone, .{ .tolerance = self.options.tolerance });
        },
    };
    return store(self, &self.shapes, id, result);
}

fn clipRegion(self: anytype, id: u32) anyerror!*const Path {
    if (self.clip_regions.get(id)) |known| return known;
    const clip = self.clips.items[id];
    const result = region: {
        var empty = Path.init(self.gpa);
        defer empty.deinit();
        var own = try combine(self, clip.path, empty, .unite);
        const parent = clip.parent orelse break :region own;
        defer own.deinit();
        break :region try combine(self, own, (try clipRegion(self, parent)).*, .intersect);
    };
    return store(self, &self.clip_regions, id, result);
}

/// Where a paint shows: its shape within the clips around it.
fn leafCoverage(self: anytype, id: u32) !*const Path {
    const leaf = self.leaves.items[id];
    const own = try shape(self, id);
    const clip = leaf.clip orelse return own;
    if (self.leaf_coverages.get(id)) |known| return known;
    return store(self, &self.leaf_coverages, id, try combine(self, own.*, (try clipRegion(self, clip)).*, .intersect));
}

/// Where a unit paints: its geometry's coverage within its clips.
pub fn coverage(self: anytype, unit: Unit) !*const Path {
    const own = try leafCoverage(self, unit.geometry);
    if (unit.clips.len == 0) return own;
    if (self.coverages.get(unit.serial)) |known| return known;
    const result = region: {
        var bounded = try own.clone(self.gpa);
        errdefer bounded.deinit();
        for (unit.clips) |clip| {
            const next = try combine(self, bounded, (try leafCoverage(self, clip)).*, .intersect);
            bounded.deinit();
            bounded = next;
        }
        break :region bounded;
    };
    return store(self, &self.coverages, unit.serial, result);
}
