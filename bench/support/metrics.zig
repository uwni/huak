const std = @import("std");
const builtin = @import("builtin");
const resources = @import("resources");

pub fn milliseconds(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(end).toNanoseconds())) / 1_000_000;
}

pub fn peakRssBytes() u64 {
    var usage: resources.struct_rusage = undefined;
    if (resources.getrusage(resources.RUSAGE_SELF, &usage) != 0) return 0;
    const value: u64 = @intCast(usage.ru_maxrss);
    return if (builtin.os.tag == .macos) value else value * 1024;
}
