//! The original cubic's frame for each flattened span, read along the contour.
const Path = @import("../../path/Path.zig");

pub const FrameSpan = struct {
    segment: *const Path.SegmentFrame,
    lo: f64,
    hi: f64,

    pub fn parameter(self: FrameSpan, fraction: f64) f64 {
        if (fraction == 1) return self.hi;
        return self.lo + (self.hi - self.lo) * fraction;
    }
};

// Walk source segments once, including across pen-up moves. Mark times
// identify the source interval even when a cubic was flattened many times.
pub const FrameReader = struct {
    reader: Path.CurveReader,
    next: usize = 0,
    cached: Path.SegmentFrame = undefined,
    path: *const Path,
    knot_cursor: usize = 0,
    max_delta: f64,

    pub fn span(self: *FrameReader, start: f64, stop: f64) !FrameSpan {
        const index: usize = @intFromFloat(start);
        if (index >= self.next) {
            const source = try self.reader.read(index - self.next);
            self.cached = try Path.SegmentFrame.init(source.curve, source.is_cubic);
            if (source.is_cubic and self.path.knots != null) {
                const raw = self.path.segments.items.len - self.reader.segments.len - 1;
                try self.cached.useSolved(self.path.knots.?.directionsForward(self.path.segments.items, raw, source.curve, &self.knot_cursor), self.max_delta);
            }
            self.next = index + 1;
        }
        const base: f64 = @floatFromInt(index);
        return .{ .segment = &self.cached, .lo = start - base, .hi = stop - base };
    }
};
