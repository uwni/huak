//! Tests of the command-line grammar: run and watch flags, rejected arguments, owned lists, check, disassembly and help, and parallel output jobs.
const std = @import("std");
const cli_options = @import("options.zig");
const Engine = cli_options.Engine;
const parse = cli_options.parse;
const Command = cli_options.Command;

/// The engine as the tests expect the language and renderer to name things.
const test_engine: Engine = .{ .default_output = "default", .formats = &.{ "svg", "pdf" } };

fn rejected(args: []const []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), args, test_engine, &diagnostic));
    try std.testing.expect(std.mem.find(u8, diagnostic.?, expected) != null);
}

test "run flags preserve literal strings and repeated font paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    const options = try parse(arena.allocator(), &.{ "run", "drawing.huak", "--param", "count=200", "--param=title=\"); panic(\"x\")", "--param", "empty=", "--output", "out.pdf", "--output=detail=more=detail.svg", "--output=detail=other.pdf", "--libtypst=custom.dylib", "--font", "one.ttf", "--font=two.otf", "--font-path", "fonts", "--font-path=more fonts", "--system-fonts", "--no-bundled-fonts" }, test_engine, &diagnostic);
    try std.testing.expectEqual(Command.run, options.command);
    try std.testing.expectEqualStrings("drawing.huak", options.script.?);
    try std.testing.expectEqualStrings("custom.dylib", options.library.?);
    try std.testing.expectEqual(@as(usize, 3), options.outputs.len);
    try std.testing.expectEqualStrings(test_engine.default_output, options.outputs[0].name);
    try std.testing.expectEqualStrings("out.pdf", options.outputs[0].path);
    try std.testing.expectEqualStrings("detail", options.outputs[1].name);
    try std.testing.expectEqualStrings("more=detail.svg", options.outputs[1].path);
    try std.testing.expectEqual(@as(usize, 2), options.fonts.len);
    try std.testing.expectEqual(@as(usize, 2), options.font_dirs.len);
    try std.testing.expectEqualStrings("more fonts", options.font_dirs[1]);
    try std.testing.expect(options.system_fonts);
    try std.testing.expectEqualStrings("\"); panic(\"x\")", options.parameters[1].value);
    try std.testing.expectEqualStrings("", options.parameters[2].value);
    try std.testing.expect(!options.bundled_fonts);
    try std.testing.expect(diagnostic == null);
}

test "watch shares run options and reserves JSON events for watch" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    const options = try parse(arena.allocator(), &.{ "watch", "--json", "--output", "default=preview.svg", "--param", "count=3", "drawing.huak", "--font", "custom.otf", "-j2" }, test_engine, &diagnostic);
    try std.testing.expectEqual(Command.watch, options.command);
    try std.testing.expect(options.json);
    try std.testing.expectEqualStrings("drawing.huak", options.script.?);
    try std.testing.expectEqualStrings(test_engine.default_output, options.outputs[0].name);
    try std.testing.expectEqualStrings("count", options.parameters[0].name);
    try std.testing.expectEqual(@as(?usize, 2), options.jobs);
    try rejected(&.{ "run", "drawing.huak", "--json" }, "only valid with watch");
    try rejected(&.{ "watch", "drawing.huak", "--json", "--json" }, "duplicate option");
}

test "command grammar rejects unknown duplicate and incomplete arguments" {
    try rejected(&.{}, "expected");
    try rejected(&.{"unknown"}, "unknown command");
    try rejected(&.{"run"}, "missing script");
    try rejected(&.{ "run", "a.huak", "b.huak" }, "unexpected positional");
    try rejected(&.{ "run", "a.huak", "--unknown" }, "unknown option");
    try rejected(&.{ "run", "a.huak", "--param" }, "missing value");
    try rejected(&.{ "run", "a.huak", "--font", "--libtypst", "lib.so" }, "missing value");
    try rejected(&.{ "run", "a.huak", "--param", "=value" }, "name must not");
    try rejected(&.{ "run", "a.huak", "--param", "name" }, "NAME=VALUE");
    try rejected(&.{ "run", "a.huak", "--param", "x=1", "--param", "x=2" }, "duplicate parameter");
    try rejected(&.{ "run", "a.huak", "--output", "--font", "a.ttf" }, "missing value");
    try rejected(&.{ "run", "a.huak", "--output=foo=" }, "path must not be empty");
    try rejected(&.{ "run", "a.huak", "--output==a.svg" }, "name must be an identifier");
    try rejected(&.{ "run", "a.huak", "--output=bad-name=a.svg" }, "name must be an identifier");
    try rejected(&.{ "run", "a.huak", "--output=a.png" }, ".svg or .pdf");
    try rejected(&.{ "run", "a.huak", "--output=one=a.svg", "--output=two=a.svg" }, "duplicate output path");
    try rejected(&.{ "check", "a.huak", "--output=a.svg" }, "only valid with run");
    try rejected(&.{ "run", "a.huak", "--no-bundled-fonts", "--no-bundled-fonts" }, "duplicate option");
    try rejected(&.{ "run", "a.huak", "--system-fonts", "--system-fonts" }, "duplicate option '--system-fonts'");
    try rejected(&.{ "run", "a.huak", "--font-path=" }, "empty value for '--font-path'");
    try rejected(&.{ "check", "a.huak", "--system-fonts" }, "only valid with run");
    try rejected(&.{ "run", "a.huak", "--libtypst=one", "--libtypst", "two" }, "duplicate option '--libtypst'");
    try rejected(&.{ "check", "a.huak", "--param", "a=1" }, "only valid with run");
    try rejected(&.{ "--", "run" }, "unknown command");
    try rejected(&.{ "--help", "run" }, "help does not accept");
    try rejected(&.{ "help", "run" }, "help does not accept");
}

test "arguments preserve owned lists and attached option-like values" {
    const allocator = std.testing.allocator;
    var diagnostic: ?[]const u8 = null;
    const options = try parse(allocator, &.{ "run", "--libtypst=--syntax-library", "--font=--font.ttf", "--param=label=--literal", "--output=--drawing.svg", "--", "-drawing.huak" }, test_engine, &diagnostic);
    defer allocator.free(options.parameters);
    defer allocator.free(options.fonts);
    defer allocator.free(options.font_dirs);
    defer allocator.free(options.outputs);
    try std.testing.expect(diagnostic == null);
    try std.testing.expectEqualStrings("-drawing.huak", options.script.?);
    try std.testing.expectEqualStrings("--syntax-library", options.library.?);
    try std.testing.expectEqualStrings("--font.ttf", options.fonts[0]);
    try std.testing.expectEqualStrings("label", options.parameters[0].name);
    try std.testing.expectEqualStrings("--literal", options.parameters[0].value);
    try std.testing.expectEqualStrings("--drawing.svg", options.outputs[0].path);
}

test "check disassembly help and explicit positional separator" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    const help = try parse(arena.allocator(), &.{"--help"}, test_engine, &diagnostic);
    try std.testing.expectEqual(Command.help, help.command);
    const check = try parse(arena.allocator(), &.{ "check", "--libtypst", "lib.so", "a.huak" }, test_engine, &diagnostic);
    try std.testing.expectEqual(Command.check, check.command);
    const disassemble = try parse(arena.allocator(), &.{ "disassemble", "--", "-a.huak" }, test_engine, &diagnostic);
    try std.testing.expectEqual(Command.disassemble, disassemble.command);
    try std.testing.expectEqualStrings("-a.huak", disassemble.script.?);
}

test "parallel output jobs use clap long and short options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    const automatic = try parse(arena.allocator(), &.{ "run", "a.huak" }, test_engine, &diagnostic);
    try std.testing.expect(automatic.jobs == null);
    for ([_][]const []const u8{
        &.{ "run", "a.huak", "--jobs", "3" },
        &.{ "run", "--jobs=3", "a.huak" },
        &.{ "run", "a.huak", "-j", "3" },
        &.{ "run", "a.huak", "-j3" },
        &.{ "run", "a.huak", "--jobs=+3" },
    }) |args| {
        const options = try parse(arena.allocator(), args, test_engine, &diagnostic);
        try std.testing.expectEqual(@as(?usize, 3), options.jobs);
        try std.testing.expect(diagnostic == null);
    }
    const serial = try parse(arena.allocator(), &.{ "run", "a.huak", "--jobs=1" }, test_engine, &diagnostic);
    try std.testing.expectEqual(@as(?usize, 1), serial.jobs);
}

test "parallel output jobs reject invalid duplicate and non-run options" {
    for ([_][]const u8{ "0", "-1", "1.5", "many", "", "999999999999999999999999999999999999999999" }) |value|
        try rejected(&.{ "run", "a.huak", "--jobs", value }, "positive integer");
    try rejected(&.{ "run", "a.huak", "--jobs" }, "missing value");
    try rejected(&.{ "run", "a.huak", "--jobs", "--font", "a.ttf" }, "missing value");
    try rejected(&.{ "run", "a.huak", "--jobs=2", "-j3" }, "duplicate option '--jobs'");
    try rejected(&.{ "check", "a.huak", "--jobs=2" }, "only valid with run");
    try rejected(&.{ "disassemble", "a.huak", "-j2" }, "only valid with run");
}
