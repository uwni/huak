//! On/off placement of a dash pattern along one line or cubic by physical arc length, with the pattern cursor that carries its phase across segments.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const Measure = @import("../../path/Measure.zig");
const Options = @import("../outline.zig").Options;
const dash = @import("../dash.zig");
const Builder = @This();

result: Path,
state: State,
options: Options,
open: bool = false,
visits: usize = 0,
mapping: ?*std.ArrayList(dash.SourceSpan) = null,
contour: usize = 0,

fn record(self: *Builder, begin: f64, end: f64) dash.Error!void {
    if (self.mapping) |mapping| try mapping.append(self.result.allocator, .{ .contour = self.contour, .begin = begin, .end = end });
}
fn move(self: *Builder, point: g.Point, time: f64) dash.Error!void {
    try self.result.moveTo(point);
    try self.record(time, time);
}
fn emitLine(self: *Builder, point: g.Point, begin: f64, end: f64) dash.Error!void {
    try self.result.lineTo(point);
    try self.record(begin, end);
}
fn emitCubic(self: *Builder, curve: g.Cubic, begin: f64, end: f64) dash.Error!void {
    try self.result.cubicTo(curve.p1, curve.p2, curve.p3);
    try self.record(begin, end);
}

fn visit(self: *Builder) dash.Error!void {
    self.visits += 1;
    if (self.visits > self.options.max_segments) return error.StrokeWorkLimit;
}
fn zeros(self: *Builder, point: g.Point, time: f64) dash.Error!void {
    while (self.state.remaining == 0) {
        try self.visit();
        if (self.state.on()) {
            try self.move(point, time);
            try self.emitLine(point, time, time);
            self.open = false;
        }
        self.state.next();
    }
    if (!self.state.on()) self.open = false;
}
pub fn line(self: *Builder, start: g.Point, end: g.Point, begin_time: f64, end_time: f64) dash.Error!void {
    const delta = end.sub(start);
    const length = delta.norm();
    if (!delta.isFinite() or !std.math.isFinite(length)) return error.NonFinite;
    try self.zeros(start, begin_time);
    if (length == 0) {
        if (self.state.on() and !self.open) {
            try self.visit();
            try self.move(start, begin_time);
            try self.emitLine(start, begin_time, end_time);
            self.open = true;
        }
        return;
    }
    var consumed: f64 = 0;
    var point = start;
    while (consumed < length) {
        try self.visit();
        const amount = @min(self.state.remaining, length - consumed);
        const next = consumed + amount;
        if (next == consumed) return error.PrecisionRange;
        const finish = if (next >= length) end else start.add(delta.scale(next / length));
        if (point.eql(finish)) return error.PrecisionRange;
        if (self.state.on()) {
            const from = begin_time + (end_time - begin_time) * (consumed / length);
            const to = if (next >= length) end_time else begin_time + (end_time - begin_time) * (next / length);
            if (!self.open) try self.move(point, from);
            try self.emitLine(finish, from, to);
            self.open = true;
        } else self.open = false;
        consumed = next;
        point = finish;
        self.state.remaining -= amount;
        if (self.state.remaining <= 0) {
            self.state.next();
            try self.zeros(point, if (next >= length) end_time else begin_time + (end_time - begin_time) * (next / length));
        }
    }
}
pub fn cubic(self: *Builder, curve: g.Cubic, measured: Measure, begin: f64, end: f64, time: f64) dash.Error!void {
    const length = end - begin;
    try self.zeros(curve.p0, time);
    if (length == 0) {
        if (self.state.on()) {
            try self.visit();
            if (!self.open) try self.move(curve.p0, time);
            try self.emitCubic(curve, time, time + 1);
            self.open = true;
        }
        return;
    }
    var consumed: f64 = 0;
    var parameter: f64 = 0;
    var point = curve.p0;
    while (consumed < length) {
        try self.visit();
        const amount = @min(self.state.remaining, length - consumed);
        const next = consumed + amount;
        if (next == consumed) return error.PrecisionRange;
        const finish = if (next >= length) 1 else std.math.clamp((measured.sample(begin + next) catch |err| switch (err) {
            error.InvalidParameter => return error.PrecisionRange,
            error.ZeroVector => return error.PrecisionRange,
            error.EmptyPath => return error.InvalidPath,
            error.NonFinite => return error.NonFinite,
        }).time - time, 0, 1);
        if (finish <= parameter) return error.PrecisionRange;
        const cut = curve.trimmed(parameter, finish) catch return error.PrecisionRange;
        if (!cut.isFinite()) return error.NonFinite;
        if (cut.p0.eql(cut.p1) and cut.p0.eql(cut.p2) and cut.p0.eql(cut.p3)) return error.PrecisionRange;
        if (self.state.on()) {
            if (!self.open) try self.move(cut.p0, time + parameter);
            try self.emitCubic(cut, time + parameter, time + finish);
            self.open = true;
        } else self.open = false;
        consumed = next;
        parameter = finish;
        point = cut.p3;
        self.state.remaining -= amount;
        if (self.state.remaining <= 0) {
            self.state.next();
            try self.zeros(point, time + finish);
        }
    }
}

pub const State = struct {
    pattern: []const f64,
    index: usize = 0,
    remaining: f64 = 0,
    fn on(self: State) bool {
        return self.index % 2 == 0;
    }
    fn next(self: *State) void {
        self.index = (self.index + 1) % (if (self.pattern.len % 2 == 0) self.pattern.len else self.pattern.len * 2);
        self.remaining = self.pattern[self.index % self.pattern.len];
    }
    pub fn init(pattern: []const f64, phase: f64, period: f64) State {
        var state: State = .{ .pattern = pattern, .remaining = pattern[0] };
        var offset = @mod(phase, period);
        while (offset > 0) {
            if (offset < state.remaining) {
                state.remaining -= offset;
                break;
            }
            offset -= state.remaining;
            state.next();
        }
        return state;
    }
};
