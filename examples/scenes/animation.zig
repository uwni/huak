//! Reusable example scene and animation geometry. No CLI, I/O or benchmarks.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const a = huak.animation;
const sampling = huak.sampling;
const motion = huak.motion;
const demo = @import("drawing_scene");
const g = huak.core.geometry;
const Path = huak.core.Path;
const DisplayList = huak.core.DisplayList;
const hobby = huak.core.hobby;

pub const requests = demo.requests;
pub const width = demo.width;
pub const height = demo.height;
pub const duration: f64 = 2;
pub const tolerance: f64 = 0.05;
pub const marker_id: u64 = 15;
pub const curve_id: u64 = 6;
pub const middle_box_id: u64 = 11;
pub const middle_label_id: u64 = 12;
const blue: DisplayList.Color = .{ .r = 0.13, .g = 0.42, .b = 0.70 };
const red: DisplayList.Color = .{ .r = 0.85, .g = 0.22, .b = 0.28 };
const scales = [_]a.PointKey{
    .{ .time = 0, .value = .{ .x = 1, .y = 1 } },
    .{ .time = 0.5, .value = .{ .x = 1.6, .y = 1.6 } },
    .{ .time = 1, .value = .{ .x = 1, .y = 1 } },
};
const colors = [_]a.ColorKey{
    .{ .time = 0, .value = blue }, .{ .time = 0.5, .value = red }, .{ .time = 1, .value = blue },
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    samples: sampling.Samples,
    translations: []a.PointKey,
    orbit: []Path.Segment,

    pub fn init(allocator: std.mem.Allocator, measured: []const typst.Metrics) !Prepared {
        var samples = try sampling.samplePaths(allocator, measured, curveAt, .{ .tolerance = tolerance });
        errdefer samples.deinit();
        const translations = try allocator.alloc(a.PointKey, samples.keys.len);
        errdefer allocator.free(translations);
        for (samples.keys, translations) |key, *translation| translation.* = .{ .time = key.time, .value = .{ .x = 0, .y = delta(key.time) } };
        var base = try buildBase(allocator, measured);
        defer base.deinit();
        const orbit_ref = base.picture.commands.items[base.objects.orbit].path.path;
        const orbit = try allocator.dupe(Path.Segment, base.picture.storage.segments.items[orbit_ref.first..][0..orbit_ref.count]);
        return .{ .allocator = allocator, .samples = samples, .translations = translations, .orbit = orbit };
    }
    pub fn deinit(self: *Prepared) void {
        self.samples.deinit();
        self.allocator.free(self.translations);
        self.allocator.free(self.orbit);
        self.* = undefined;
    }
    pub fn tracks(self: *const Prepared) [6]a.Track {
        return .{
            .{ .target = curve_id, .property = .{ .path = self.samples.keys } },
            .{ .target = middle_box_id, .property = .{ .translate = self.translations } },
            .{ .target = middle_label_id, .property = .{ .translate = self.translations } },
            .{ .target = marker_id, .property = .{ .motion = .{ .path = self.orbit, .rotate = .auto } } },
            .{ .target = marker_id, .property = .{ .scale = &scales } },
            .{ .target = marker_id, .property = .{ .fill = &colors } },
        };
    }
};

pub fn buildBase(allocator: std.mem.Allocator, measured: []const typst.Metrics) !Base {
    var result = try demo.build(allocator, measured, 0);
    errdefer result.deinit();
    // The caption labels the whole moving curve. It is intentionally stationary.
    result.picture.commands.items[result.objects.caption].label.transform = .{ .d = -1, .e = 32, .f = 242 + measured[4].baseline };
    var marker = Path.init(allocator);
    defer marker.deinit();
    try marker.moveTo(.{ .x = 7, .y = 0 });
    try marker.lineTo(.{ .x = -5, .y = 4 });
    try marker.lineTo(.{ .x = -5, .y = -4 });
    try marker.close();
    const marker_ref = result.picture.commands.items.len;
    try result.picture.fill(marker, blue, .{});
    return .{ .picture = result.picture, .objects = result.objects, .marker = marker_ref };
}

pub const Base = struct {
    picture: DisplayList,
    objects: demo.Objects,
    marker: usize,
    pub fn deinit(self: *Base) void {
        self.picture.deinit();
        self.* = undefined;
    }
    pub fn objectIds(self: *const Base, allocator: std.mem.Allocator) ![]u64 {
        const ids = try allocator.alloc(u64, self.picture.commands.items.len);
        @memset(ids, 0);
        ids[self.objects.curve] = curve_id;
        ids[self.objects.node_boxes[1]] = middle_box_id;
        ids[self.objects.node_labels[1]] = middle_label_id;
        ids[self.marker] = marker_id;
        return ids;
    }
};

fn delta(time: f64) f64 {
    return if (time == 0 or time == 1) 0 else 24 * @sin(2 * std.math.pi * time);
}
fn curveAt(allocator: std.mem.Allocator, measured: []const typst.Metrics, time: f64) !Path {
    const nodes = try demo.layoutNodes(allocator, measured, delta(time));
    const knots = [_]hobby.Knot{
        .{ .point = nodes[0], .outgoing_direction = .{ .x = 1, .y = 0.45 } },
        .{ .point = nodes[1] },
        .{ .point = nodes[2], .incoming_direction = .{ .x = 1, .y = -0.15 } },
    };
    const curves = try hobby.interpolate(allocator, &knots, .{});
    defer allocator.free(curves);
    return Path.fromCubics(allocator, curves, false);
}

pub fn pictureAt(allocator: std.mem.Allocator, measured: []const typst.Metrics, prepared: *const Prepared, time: f64) !Base {
    var picture = try buildBase(allocator, measured);
    errdefer picture.deinit();
    const keys = prepared.samples.keys;
    var index: usize = 0;
    while (index + 2 < keys.len and keys[index + 1].time < time) : (index += 1) {}
    const fraction = (time - keys[index].time) / (keys[index + 1].time - keys[index].time);
    const range = picture.picture.commands.items[picture.objects.curve].path.path;
    for (picture.picture.storage.segments.items[range.first..][0..range.count], keys[index].value, keys[index + 1].value) |*segment, left, right| segment.* = switch (left) {
        .move => |point| .{ .move = point.lerp(right.move, fraction) },
        .line => |point| .{ .line = point.lerp(right.line, fraction) },
        .cubic => |curve| .{ .cubic = .{ .c1 = curve.c1.lerp(right.cubic.c1, fraction), .c2 = curve.c2.lerp(right.cubic.c2, fraction), .end = curve.end.lerp(right.cubic.end, fraction) } },
        .close => .close,
    };
    const translation = prepared.translations[index].value.lerp(prepared.translations[index + 1].value, fraction);
    picture.picture.commands.items[picture.objects.node_boxes[1]].path.transform = picture.picture.commands.items[picture.objects.node_boxes[1]].path.transform.then(g.Transform.translation(translation.x, translation.y));
    picture.picture.commands.items[picture.objects.node_labels[1]].label.transform = picture.picture.commands.items[picture.objects.node_labels[1]].label.transform.then(g.Transform.translation(translation.x, translation.y));
    const pose = try motion.motionPose(allocator, prepared.orbit, time);
    const pulse = if (time <= 0.5) 1 + time * 1.2 else 1.6 - (time - 0.5) * 1.2;
    picture.picture.commands.items[picture.marker].path.transform = g.Transform.scaling(pulse, pulse).then(g.Transform.rotation(pose.angle)).then(g.Transform.translation(pose.position.x, pose.position.y));
    const color_fraction = if (time <= 0.5) time * 2 else (1 - time) * 2;
    const marker = &picture.picture.commands.items[picture.marker].path;
    var style = marker.style.*;
    style.fill = .{
        .r = blue.r * (1 - color_fraction) + red.r * color_fraction,
        .g = blue.g * (1 - color_fraction) + red.g * color_fraction,
        .b = blue.b * (1 - color_fraction) + red.b * color_fraction,
    };
    marker.style = try picture.picture.storage.styles.replace(marker.style, &style);
    return picture;
}
