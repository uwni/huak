//! Typeset text: the registry entries, anchors, and the metric builtins.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const typesetting = @import("typesetting.zig");
const conversions = @import("conversions.zig");
const checkedIndex = conversions.checkedIndex;
const lengthResult = conversions.lengthResult;

pub const Text = struct {
    layout: *typst.Layout,
    frame: usize,
    metrics: DisplayList.Metrics,
    /// Label anchors, made on first use. The VM copies this template on each read.
    anchors: ?*types.Dict = null,
};

/// A labeled element of typeset content, in the content's own y-up coordinates:
/// the origin is the baseline start where `label` and `object` place the text.
pub const Anchor = struct { position: g.Point, min: g.Point, max: g.Point };

pub fn releaseText(gpa: std.mem.Allocator, text: *Text) void {
    const anchors = text.anchors orelse return;
    for (anchors.entries.keys()) |key| gpa.free(key);
    anchors.entries.deinit(gpa);
    gpa.destroy(anchors);
    text.anchors = null;
}

/// Maps each label of typeset content to its anchor. Typst reports a label as
/// often as it occurs; a dictionary needs each one once.
pub fn textAnchors(self: *Runtime, value: Value) !Value {
    self.native_message = "";
    const index = try checkedIndex(value, .text, self.texts.items.len);
    const text = self.texts.items[index];
    if (text.anchors) |cached| return .{ .dict = cached };
    const elements = text.layout.labels(text.frame) catch |err| {
        typesetting.captureNative(self);
        return err;
    };
    const gpa = self.gpa;
    var cached = text;
    cached.anchors = try gpa.create(types.Dict);
    cached.anchors.?.* = .{};
    errdefer releaseText(gpa, &cached);
    const result = cached.anchors.?;
    // Frame y-down points to text-local y-up coordinates.
    const local = struct {
        fn point(baseline: f64, at: typst.c.TypstPoint) g.Point {
            return .{ .x = at.x, .y = baseline - at.y };
        }
    }.point;
    const baseline = text.metrics.baseline;
    for (elements) |element| {
        const name = if (element.label.len == 0) "" else element.label.data[0..element.label.len];
        if (result.entries.contains(name)) {
            self.setMessageFormat("label <{s}> occurs more than once in the typeset content", .{name});
            return error.DuplicateLabel;
        }
        const position = local(baseline, element.position);
        const anchor: Anchor = if (element.flags & typst.c.TYPST_LABEL_EXTENT != 0) .{
            .position = position,
            .min = local(baseline, .{ .x = element.min.x, .y = element.max.y }),
            .max = local(baseline, .{ .x = element.max.x, .y = element.min.y }),
        } else .{ .position = position, .min = position, .max = position };
        const anchor_value = try conversions.store(self, Anchor, &self.anchors, anchor, .anchor);
        const key = try gpa.dupe(u8, name);
        errdefer gpa.free(key);
        try result.entries.putNoClobber(gpa, key, anchor_value);
    }
    self.texts.items[index].anchors = result;
    return .{ .dict = result };
}

/// Metrics and anchors of typeset text.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .anchors => return textAnchors(self, arg.body),
        .width, .height, .baseline => {
            const metric = (try conversions.textValue(self, arg.body)).metrics;
            return lengthResult(switch (id) {
                .width => metric.width,
                .height => metric.height,
                .baseline => metric.baseline,
                else => unreachable,
            });
        },
        else => comptime unreachable,
    }
}
