//! Parse the existing production benchmark protocol without importing a region
//! implementation. All string slices borrow the retained child stderr bytes.
const std = @import("std");

pub const case_count = 21;
pub const trial_count = 3;

pub const Case = struct {
    name: []const u8,
    operation: []const u8,
    tolerance: f64,
    repeats: usize,
    first_call_us: f64,
    hot_median_us: f64,
    trials_us: [trial_count]f64,
    elements: usize,
    cubics: usize,
    lines: usize,
    peak_rss_bytes: u64,
    checksum: usize,
};

pub const Report = struct {
    header: []const u8,
    timing: []const u8,
    baseline_peak_rss_bytes: u64,
    cases: [case_count]Case,
};

fn field(line: []const u8, name: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    while (tokens.next()) |token| {
        if (token.len <= name.len or token[name.len] != '=' or !std.mem.eql(u8, token[0..name.len], name)) continue;
        if (found != null) return error.DuplicateField;
        found = token[name.len + 1 ..];
    }
    const value = found orelse return error.MissingField;
    if (value.len == 0) return error.EmptyField;
    return value;
}

fn number(line: []const u8, name: []const u8) !f64 {
    const value = try std.fmt.parseFloat(f64, try field(line, name));
    if (!std.math.isFinite(value) or value < 0) return error.InvalidMeasurement;
    return value;
}

fn integer(comptime T: type, line: []const u8, name: []const u8) !T {
    return std.fmt.parseInt(T, try field(line, name), 10);
}

fn parseCase(line: []const u8) !Case {
    var result: Case = .{
        .name = try field(line, "case"),
        .operation = try field(line, "operation"),
        .tolerance = try number(line, "tolerance"),
        .repeats = try integer(usize, line, "repeats"),
        .first_call_us = try number(line, "first_call_us"),
        .hot_median_us = try number(line, "hot_median_us"),
        .trials_us = undefined,
        .elements = try integer(usize, line, "elements"),
        .cubics = try integer(usize, line, "cubics"),
        .lines = try integer(usize, line, "lines"),
        .peak_rss_bytes = try integer(u64, line, "peak_rss_bytes"),
        .checksum = try integer(usize, line, "checksum"),
    };
    if (result.repeats == 0 or result.tolerance == 0) return error.InvalidCaseMetadata;
    const operation = result.operation;
    if (!std.mem.eql(u8, operation, "difference") and !std.mem.eql(u8, operation, "intersection") and !std.mem.eql(u8, operation, "unite") and !std.mem.eql(u8, operation, "xor")) return error.InvalidCaseMetadata;
    const trials = try field(line, "trials_us");
    if (trials.len < 2 or trials[0] != '[' or trials[trials.len - 1] != ']') return error.InvalidTrials;
    var parts = std.mem.splitScalar(u8, trials[1 .. trials.len - 1], ',');
    for (&result.trials_us) |*value| {
        value.* = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidTrialCount);
        if (!std.math.isFinite(value.*) or value.* < 0) return error.InvalidMeasurement;
    }
    if (parts.next() != null) return error.InvalidTrialCount;
    var ordered = result.trials_us;
    std.mem.sort(f64, &ordered, {}, std.sort.asc(f64));
    if (ordered[trial_count / 2] != result.hot_median_us) return error.InconsistentMedian;
    if (result.cubics > result.elements or result.lines > result.elements - result.cubics) return error.InvalidCaseCounts;
    if (result.checksum != result.elements *% result.repeats *% trial_count) return error.InconsistentChecksum;
    return result;
}

pub fn parse(bytes: []const u8) !Report {
    var header: ?[]const u8 = null;
    var timing: ?[]const u8 = null;
    var baseline: ?u64 = null;
    var cases: [case_count]Case = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "regions / Zig ")) {
            if (header != null) return error.DuplicateHeader;
            if (try integer(usize, line, "trials") != trial_count) return error.InvalidTrialCount;
            header = line;
        } else if (std.mem.startsWith(u8, line, "timing=")) {
            if (timing != null) return error.DuplicateHeader;
            timing = line["timing=".len..];
        } else if (std.mem.startsWith(u8, line, "peak_rss_bytes=")) {
            if (baseline != null) return error.DuplicateHeader;
            baseline = try integer(u64, line, "baseline_peak_rss_bytes");
        } else if (std.mem.startsWith(u8, line, "case=")) {
            if (count == cases.len) return error.InvalidCaseCount;
            const value = try parseCase(line);
            for (cases[0..count]) |previous| if (std.mem.eql(u8, previous.name, value.name)) return error.DuplicateCase;
            cases[count] = value;
            count += 1;
        }
    }
    if (count != cases.len) return error.InvalidCaseCount;
    return .{ .header = header orelse return error.MissingHeader, .timing = timing orelse return error.MissingHeader, .baseline_peak_rss_bytes = baseline orelse return error.MissingHeader, .cases = cases };
}

/// Inputs and configuration must agree across engines and every process.
/// Element counts may legitimately differ between implementations.
pub fn verifyMetadata(expected: Report, actual: Report) !void {
    if (!std.mem.eql(u8, expected.header, actual.header)) return error.ConfigurationMismatch;
    for (expected.cases, actual.cases) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.operation, b.operation) or a.tolerance != b.tolerance or a.repeats != b.repeats) {
            std.debug.print("case metadata changed: expected {s} {s} tolerance={e} repeats={d}, got {s} {s} tolerance={e} repeats={d}\n", .{ a.name, a.operation, a.tolerance, a.repeats, b.name, b.operation, b.tolerance, b.repeats });
            return error.CaseMetadataMismatch;
        }
    }
}

/// Each engine must remain deterministic relative to its own warmup.
pub fn verifyOutput(expected: Report, actual: Report) !void {
    for (expected.cases, actual.cases) |a, b| {
        if (a.elements != b.elements or a.cubics != b.cubics or a.lines != b.lines or a.checksum != b.checksum) return error.RegionOutputChanged;
    }
}

pub const Statistics = struct { median: f64, min: f64, max: f64 };

/// The caller provides scratch storage. Even-sized samples use the arithmetic
/// mean of the two middle observations, not the upper middle observation.
pub fn statistics(values: []f64) Statistics {
    std.debug.assert(values.len != 0);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    const median = if (values.len % 2 == 0) values[middle - 1] * 0.5 + values[middle] * 0.5 else values[middle];
    return .{ .median = median, .min = values[0], .max = values[values.len - 1] };
}

const test_prefix = "case=lens operation=intersection tolerance=1e-3 repeats=200 first_call_us=1 hot_median_us=2 ";
const test_suffix = " elements=6 cubics=4 lines=0 peak_rss_bytes=100 checksum=3600";
const test_line = test_prefix ++ "trials_us=[1,2,3]" ++ test_suffix;

test "region comparison rejects partial trials, duplicate fields and inconsistent medians" {
    const t = std.testing;
    const value = try parseCase(test_line);
    try t.expectEqual(@as(f64, 2), value.hot_median_us);
    try t.expectError(error.InvalidTrialCount, parseCase(test_prefix ++ "trials_us=[1,2]" ++ test_suffix));
    try t.expectError(error.InvalidTrialCount, parseCase(test_prefix ++ "trials_us=[1,2,3,4]" ++ test_suffix));
    try t.expectError(error.DuplicateField, parseCase(test_line ++ " repeats=200"));
    try t.expectError(error.InconsistentMedian, parseCase(test_prefix ++ "trials_us=[1,3,4]" ++ test_suffix));
    try t.expectError(error.InvalidMeasurement, parseCase(test_prefix ++ "trials_us=[1,nan,3]" ++ test_suffix));
    try t.expectError(error.InvalidCaseCount, parse(test_line));
}

test "region comparison separates shared input metadata from engine-specific output counts" {
    const t = std.testing;
    var log: std.Io.Writer.Allocating = .init(t.allocator);
    defer log.deinit();
    try log.writer.writeAll("regions / Zig 0.17.0 / fast / macos-aarch64; trials=3\ntiming=example\npeak_rss_bytes=whole-process baseline_peak_rss_bytes=100\n");
    for (0..case_count) |index| try log.writer.print("case=c{d} operation=difference tolerance=1e-3 repeats=200 first_call_us=1 hot_median_us=2 trials_us=[1,2,3]{s}\n", .{ index, test_suffix });
    const expected = try parse(log.written());
    var actual = expected;
    actual.cases[0].elements += 1;
    try verifyMetadata(expected, actual);
    try t.expectError(error.RegionOutputChanged, verifyOutput(expected, actual));
    actual = expected;
    actual.cases[0].repeats += 1;
    try t.expectError(error.CaseMetadataMismatch, verifyMetadata(expected, actual));
    try log.writer.print("{s}\n", .{test_line});
    try t.expectError(error.InvalidCaseCount, parse(log.written()));
}

test "region comparison statistics retain extrema and a conventional even median" {
    var values = [_]f64{ 9, 1, 7, 3 };
    const actual = statistics(&values);
    try std.testing.expectEqual(Statistics{ .median = 5, .min = 1, .max = 9 }, actual);
}
