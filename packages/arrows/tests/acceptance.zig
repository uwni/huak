//! Run from packages/arrows: zig run -OReleaseSafe tests/acceptance.zig -- HUAK LIBTYPST
//! The package through the real CLI, Poppler's rasterizer and the SVG renderer.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedHuakAndLibrary;
    const check: Check = .{ .a = a, .io = init.io, .binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], a), .library = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a) };
    try std.Io.Dir.cwd().createDirPath(init.io, "target/acceptance");
    for ([_][]const u8{ "joins", "marks", "line" }) |name| {
        try contains(try check.huak(&.{ "run", try check.fmt("tests/{s}.huak", .{name}) }, true), "checks passed");
    }
    for ([_][2][]const u8{ .{ "several-subpaths", "one subpath" }, .{ "no-width", "the pen must have a width across the line" } }) |failure| {
        try contains(try check.huak(&.{ "run", try check.fmt("tests/fixtures/{s}.huak", .{failure[0]}) }, false), failure[1]);
    }
    // No seam through Poppler: along each arrow's axis the ink stays dark from
    // the shaft into the head, while a shaft butted against a head shows one;
    // a gradient runs on from the shaft into the head without a step.
    _ = try check.huak(&.{ "run", "tests/seams.huak", "--output=target/acceptance/seams.pdf", "--output=target/acceptance/seams.svg" }, true);
    _ = try check.process(&.{ "pdftoppm", "-r", "288", "-singlefile", "target/acceptance/seams.pdf", "target/acceptance/seams" }, true);
    try verifySeams(try check.read("target/acceptance/seams.ppm"));
    _ = try check.process(&.{ "rsvg-convert", "-z", "4", "-o", "target/acceptance/seams.png", "target/acceptance/seams.svg" }, true);
    // The examples render to SVG and PDF; the PNGs are for looking at.
    for ([_][]const u8{ "catalog", "curves" }) |name| {
        const source = try check.fmt("examples/{s}.huak", .{name});
        _ = try check.huak(&.{ "check", source }, true);
        _ = try check.huak(&.{ "run", source, try check.fmt("--output=target/acceptance/{s}.svg", .{name}), try check.fmt("--output=target/acceptance/{s}.pdf", .{name}) }, true);
        try contains(try check.read(try check.fmt("target/acceptance/{s}.pdf", .{name})), "%PDF-");
        _ = try check.process(&.{ "rsvg-convert", "-z", "3", "-o", try check.fmt("target/acceptance/{s}.png", .{name}), try check.fmt("target/acceptance/{s}.svg", .{name}) }, true);
        _ = try check.process(&.{ "pdftoppm", "-r", "216", "-singlefile", "-png", try check.fmt("target/acceptance/{s}.pdf", .{name}), try check.fmt("target/acceptance/{s}-pdf", .{name}) }, true);
    }
    std.debug.print("arrows acceptance passed\n", .{});
}

const Check = struct {
    a: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    library: []const u8,
    fn fmt(self: Check, comptime pattern: []const u8, args: anytype) ![]const u8 {
        return self.a.print(pattern, args);
    }
    fn read(self: Check, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(64 * 1024 * 1024));
    }
    fn process(self: Check, argv: []const []const u8, success: bool) ![]const u8 {
        const result = try std.process.run(self.a, self.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
        if (result.term != .exited or (result.term.exited == 0) != success) {
            std.debug.print("{any}\n{s}\n{s}\n", .{ argv, result.stdout, result.stderr });
            return error.UnexpectedProcessResult;
        }
        return if (success) result.stdout else result.stderr;
    }
    fn huak(self: Check, args: []const []const u8, success: bool) ![]const u8 {
        const argv = try self.a.alloc([]const u8, args.len + 3);
        argv[0] = self.binary;
        @memcpy(argv[1 .. args.len + 1], args);
        argv[args.len + 1] = "--libtypst";
        argv[args.len + 2] = self.library;
        return self.process(argv, success);
    }
};

fn contains(bytes: []const u8, expected: []const u8) !void {
    if (std.mem.find(u8, bytes, expected) == null) {
        std.debug.print("Expected {s}:\n{s}\n", .{ expected, bytes });
        return error.MissingExpectedText;
    }
}

// tests/seams.huak on a 120 x 205 pt page at 288 dpi, four pixels to the
// point. Row i's axis is 190.37 - 20 i pt above the bottom; its shaft starts
// at 10.37 pt and its head ends at 100.37 pt. Rows 0 to 4 are solid arrows
// and row 5 their control; row 6 is a gradient arrow and row 7 its control;
// row 8 is a translucent arrow and row 9 its control.
fn verifySeams(ppm: []const u8) !void {
    const header = "P6\n480 820\n255\n";
    if (!std.mem.startsWith(u8, ppm, header) or ppm.len != header.len + 480 * 820 * 3) return error.UnexpectedRaster;
    const pixels = ppm[header.len..];
    for (0..10) |i| {
        const axis = 190.37 - 20 * @as(f64, @floatFromInt(i));
        const row: usize = @intFromFloat(@floor((205 - axis) * 4));
        var lightest: u8 = 0;
        var darkest: u8 = 255;
        var step: u8 = 0;
        // From well inside the shaft to where the head is still wide.
        const first: usize = @intFromFloat((10.37 + 4) * 4);
        for (first..@as(usize, @intFromFloat((100.37 - 3) * 4))) |x| {
            const p = pixels[(row * 480 + x) * 3 ..][0..3];
            lightest = @max(lightest, p[0], p[1], p[2]);
            darkest = @min(darkest, p[0]);
            if (x > first) {
                const q = pixels[(row * 480 + x - 1) * 3];
                step = @max(step, @max(p[0], q) - @min(p[0], q));
            }
        }
        const failed = switch (i) {
            0...4 => lightest >= 30,
            5 => lightest < 30,
            6 => step > 3,
            8 => step > 3 or lightest - darkest > 6,
            else => step <= 10,
        };
        if (failed) {
            std.debug.print("row {d}: lightest {d}, darkest {d}, largest step {d}\n", .{ i, lightest, darkest, step });
            return error.SeamBetweenShaftAndHead;
        }
    }
}
