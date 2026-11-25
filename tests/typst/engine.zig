//! What an engine is created with: immutable inputs, the sandboxed context, and fonts.
const std = @import("std");
const testing = std.testing;
const options = @import("test_options");
const typst = @import("libtypst");

const font_fixture = @embedFile("../fixtures/fonts/LibertinusSerif-Regular.otf");

test "engine inputs are immutable strings copied before the caller releases storage" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const key = try testing.allocator.dupe(u8, "caption");
    const value = try testing.allocator.dupe(u8, "Fixed Ω input");
    var engine = try library.createEngineWithOptions(&.{ .inputs = &.{.{ .key = key, .value = value }} });
    defer engine.deinit();
    testing.allocator.free(key);
    testing.allocator.free(value);
    var document = try engine.compile("#assert(sys.inputs.caption == \"Fixed Ω input\")\n#sys.inputs.caption");
    defer document.deinit();
    var metrics: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{.{ .source = "sys.inputs.caption", .syntax = .code }}, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width > 20);
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .inputs = &.{ .{ .key = "duplicate", .value = "1" }, .{ .key = "duplicate", .value = "2" } } }));
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .inputs = &.{.{ .key = "", .value = "empty" }} }));
}

test "custom font bytes are copied and retained by independent text frames" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const copy = try testing.allocator.dupe(u8, font_fixture);
    var engine = try library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = copy }}, .use_bundled_fonts = false });
    defer engine.deinit();
    testing.allocator.free(copy);
    var metrics: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{.{ .source = "Retained custom font" }}, &metrics, null);
    defer layout.deinit();
    engine.deinit();
    const native = try (try layout.frame(0)).nativeLayout(&library);
    var actual: typst.c.TypstMetrics = undefined;
    try library.check(library.functions.layout_metrics(native, &actual), null);
    try testing.expectEqual(metrics[0].width, actual.width_pt);
    try testing.expect(actual.width_pt > 0);
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = "invalid font bytes" }} }));
}

test "font directories and system fonts are discovered by libtypst" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(testing.io, "fonts/nested");
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "fonts/nested/serif.otf", .data = font_fixture });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    const directory = try std.fs.path.join(testing.allocator, &.{ buffer[0..length], "fonts" });
    defer testing.allocator.free(directory);
    // Without bundled fonts the scanned directory supplies the only face.
    var scanned = try library.createEngineWithOptions(&.{ .font_dirs = &.{directory}, .use_bundled_fonts = false });
    defer scanned.deinit();
    var metrics: [1]typst.Metrics = undefined;
    var layout = try scanned.layoutContent(&.{.{ .source = "Discovered font" }}, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width > 0);
    // Another configuration gets its own context; repeating one, as watch
    // rebuilds do, reuses it instead of scanning the system again.
    var default = try library.createEngine();
    defer default.deinit();
    var system = try library.createEngineWithOptions(&.{ .system_fonts = true });
    defer system.deinit();
    try testing.expect(system.handle != default.handle);
    var again = try library.createEngineWithOptions(&.{ .system_fonts = true });
    defer again.deinit();
    try testing.expect(again.handle == system.handle);
}

test "Huak context disables plugins and has no implicit filesystem or clock" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const cases = [_]struct { source: []const u8, marker: []const u8 }{
        .{ .source = "#plugin(\"missing.wasm\")", .marker = "plugin" },
        .{ .source = "#std.plugin(\"missing.wasm\")", .marker = "plugin" },
        .{ .source = "#eval(\"plugin\")", .marker = "plugin" },
        .{ .source = "#read(\"blocked.txt\")", .marker = "blocked.txt" },
        .{ .source = "#datetime.today()", .marker = "date" },
    };
    for (cases) |case| {
        try testing.expectError(error.CompileFailed, engine.compile(case.source));
        var message = try library.lastError();
        defer message.deinit();
        try testing.expect(std.mem.indexOf(u8, message.bytes(), case.marker) != null);
    }
}

test "custom TTC sources reject a malformed face after an otherwise valid face" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const valid = try collectionFixture(testing.allocator, font_fixture, false);
    defer testing.allocator.free(valid);
    var accepted = try library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = valid }}, .use_bundled_fonts = false });
    defer accepted.deinit();
    try testing.expect(accepted.handle != null);
    var metrics: [1]typst.Metrics = undefined;
    var layout = try accepted.layoutContent(&.{.{ .source = "Valid TTC face" }}, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width > 0);
    const invalid = try collectionFixture(testing.allocator, font_fixture, true);
    defer testing.allocator.free(invalid);
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = invalid }}, .use_bundled_fonts = false }));
    var detail = try library.lastError();
    defer detail.deinit();
    try testing.expect(std.mem.indexOf(u8, detail.bytes(), "face 1") != null);
}

/// Test data only: relocate one bundled SFNT into a two-face TTC container.
/// The production loader delegates all font parsing to the upstream C API.
fn collectionFixture(allocator: std.mem.Allocator, source: []const u8, bad_second: bool) ![]u8 {
    const prefix = 20;
    const data = try allocator.alloc(u8, prefix + source.len);
    errdefer allocator.free(data);
    @memset(data[0..prefix], 0);
    @memcpy(data[0..4], "ttcf");
    std.mem.writeInt(u32, data[4..8], 0x0001_0000, .big);
    std.mem.writeInt(u32, data[8..12], 2, .big);
    std.mem.writeInt(u32, data[12..16], prefix, .big);
    std.mem.writeInt(u32, data[16..20], if (bad_second) @intCast(data.len + 64) else prefix, .big);
    @memcpy(data[prefix..], source);
    const tables = std.mem.readInt(u16, source[4..6], .big);
    for (0..tables) |index| {
        const offset = prefix + 12 + index * 16 + 8;
        const field: *[4]u8 = @ptrCast(data[offset..][0..4]);
        std.mem.writeInt(u32, field, std.mem.readInt(u32, field, .big) + prefix, .big);
    }
    return data;
}
