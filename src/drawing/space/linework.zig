//! The line work of a projected model: its curves, split where the number of
//! layers in front of them changes, and its visible faces, divided where the
//! layers in front change, with band lighting and highlight ellipses. OCCT
//! answers every geometric question through `Model.View`; this module decides
//! what to ask and what to draw.
const std = @import("std");
const c = @import("space_c");
const g = @import("../geometry.zig");
const Model = @import("Model.zig");
const shading = @import("shading.zig");
const Work = @import("linework/Work.zig");
const Bands = @import("linework/Bands.zig");

/// The order matches the C header's projected kinds.
pub const Kind = enum(c_int) { edge, outline, smooth, seam, curve, intersection };

/// Commands start..start + count of a curve or of a region's outline.
pub const Line = struct { source: usize, start: usize, count: usize, covering: usize, kind: Kind, other: isize };
/// A region of a face behind `covering` layers, with its highlight, the
/// ellipses fitted to its face's highlights, and its bands of diffuse light;
/// `sides` are those of the face that lines of sight meet behind as many
/// layers.
pub const Face = struct {
    source: usize,
    face: usize,
    sides: shading.Sides,
    single_layer: bool = false,
    start: usize,
    count: usize,
    covering: usize,
    spot_start: usize,
    spot_count: usize,
    lobe_start: usize,
    lobe_count: usize,
    shade_start: usize,
    shade_count: usize,
};
pub const Spot = struct { center: g.Point, u: g.Point, v: g.Point };
pub const Shade = struct { start: usize, count: usize, diffuse: f64 };

pub const Linework = struct {
    commands: std.ArrayList(c.HuakPathCommand) = .empty,
    lines: std.ArrayList(Line) = .empty,
    faces: std.ArrayList(Face) = .empty,
    lobes: std.ArrayList(Spot) = .empty,
    shades: std.ArrayList(Shade) = .empty,
    /// The camera's frame as OCCT built it.
    frame: c.HuakFrame = undefined,
    /// The bounds of each face record's region, with its tolerance.
    bounds: std.ArrayList(?g.BBox) = .empty,

    pub fn deinit(self: *Linework, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.lines.deinit(allocator);
        self.faces.deinit(allocator);
        self.lobes.deinit(allocator);
        self.shades.deinit(allocator);
        self.bounds.deinit(allocator);
        self.* = undefined;
    }
};

pub const Camera = struct { azimuth: f64, elevation: f64, focus: f64 };

pub const Light = struct {
    /// Toward the light, of any length.
    direction: [3]f64,
    /// The highlight's angle around the half vector; zero for none.
    spot: f64,
    /// Increasing levels of n·l at which bands begin, the first zero.
    isophotes: []const f64,
};

/// `smooth` asks for regions that carry continuous fields: the light
/// without bands, and the script's field.
pub const Options = struct { faces: bool, light: ?Light, tolerance: f64, smooth: bool = false };

/// A view of the model for `camera`, which looks at the origin from
/// `azimuth` around z and `elevation` above the xy plane, with the screen's x
/// axis horizontal. `scratch` serves the view's conversions.
pub fn view(model: *Model, scratch: std.mem.Allocator, camera: Camera) Model.Error!Model.View {
    const eye: [3]f64 = .{ @cos(camera.elevation) * @cos(camera.azimuth), @cos(camera.elevation) * @sin(camera.azimuth), @sin(camera.elevation) };
    const x: [3]f64 = .{ -@sin(camera.azimuth), @cos(camera.azimuth), 0 };
    return model.view(scratch, eye, x, camera.focus);
}

/// The line work `view` shows of its model.
pub fn project(allocator: std.mem.Allocator, view_: *Model.View, options: Options) Model.Error!Linework {
    const model = view_.model;
    if ((options.light != null or options.smooth) and (view_.frame.focus != 0 or !options.faces)) return model.failWith("shading requires orthographic face projection");
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var result: Linework = .{ .frame = view_.frame };
    errdefer result.deinit(allocator);
    var work: Work = .{ .allocator = allocator, .scratch = arena.allocator(), .model = model, .view = view_, .out = &result, .tolerance = options.tolerance, .layered = options.faces };
    try work.collect();
    // Bands of light end at contours of the faces' light, which divide the
    // plane with the curves drawn.
    var bands: ?Bands = null;
    if (options.light) |light| if (!options.smooth) {
        bands = try Bands.init(&work, light);
        try bands.?.trace(&work);
    };
    const drawn = try work.drawLines() orelse return result;
    if (!options.faces) return result;
    if (bands) |*lit| {
        try lit.fill(&work, drawn);
    } else if (options.smooth) {
        try work.fillParts(drawn);
    } else try work.fillFaces(drawn);
    return result;
}

/// The smooth fields of each front region, from the consecutive records of
/// one face's regions at a time, with the sides of it they show; other
/// records get none.
pub fn smoothFields(work: *const Linework, lighting: *shading.Shading, out: *shading.Output, fields: []shading.Field) shading.Error!void {
    std.debug.assert(fields.len == work.faces.items.len);
    @memset(fields, .none);
    const records = work.faces.items;
    const inf = std.math.inf(f64);
    var start: usize = 0;
    while (start < records.len) {
        const first = records[start];
        var end = start + 1;
        while (end < records.len and records[end].covering == first.covering and records[end].source == first.source and records[end].face == first.face) end += 1;
        if (first.covering == 0) {
            // A region without geometry bounds nothing.
            const bounds = try lighting.allocator.alloc(g.BBox, end - start);
            defer lighting.allocator.free(bounds);
            for (work.bounds.items[start..end], bounds) |found, *box| box.* = found orelse .{ .min = .{ .x = inf, .y = inf }, .max = .{ .x = -inf, .y = -inf } };
            try lighting.fields(out, .{ .source = first.source, .index = first.face }, first.sides, bounds, first.single_layer, fields[start..end]);
        }
        start = end;
    }
}
