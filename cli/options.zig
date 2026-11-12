//! Command-line syntax only. Language parameter types are validated by the VM.
const std = @import("std");
const clap = @import("clap");

pub const Command = enum { run, watch, check, disassemble, help };
pub const Parameter = struct { name: []const u8, value: []const u8 };
pub const Output = struct { name: []const u8, path: []const u8 };
pub const Options = struct {
    command: Command,
    script: ?[]const u8 = null,
    library: ?[]const u8 = null,
    fonts: []const []const u8 = &.{},
    font_dirs: []const []const u8 = &.{},
    system_fonts: bool = false,
    bundled_fonts: bool = true,
    parameters: []const Parameter = &.{},
    outputs: []const Output = &.{},
    /// Maximum simultaneous construction/output jobs. Null selects host CPUs.
    jobs: ?usize = null,
    /// Watch events use JSON Lines on stdout; script prints remain on stderr.
    json: bool = false,
};

// The same upstream declarations drive token recognition and help output.
const main_params = clap.parseParamsComptime(
    \\--help       Display command usage.
    \\<COMMAND>    run, watch, check, disassemble or help.
);
const params = clap.parseParamsComptime(
    \\--param <NAME=VALUE>...  Set a declared script parameter.
    \\--output <[NAME=]FILE>... Export a picture to SVG or PDF; NAME defaults to default.
    \\-j, --jobs <N>         Maximum parallel jobs; defaults to available CPUs.
    \\--libtypst <PATH>       Load the native libtypst dynamic library.
    \\--font <PATH>...        Load a TTF, OTF or TTC font.
    \\--font-path <DIR>...    Use the fonts in a directory and its subdirectories.
    \\--system-fonts          Also use the fonts installed on the system.
    \\--no-bundled-fonts      Disable bundled fonts.
    \\--json                  Emit watch build events as JSON Lines.
    \\<FILE>                  Script to compile or execute.
);
const Option = enum { param, output, jobs, libtypst, font, @"font-path", @"system-fonts", @"no-bundled-fonts", json, file };
// Assign typed IDs once at comptime; runtime parsing never rematches names.
const option_params = blk: {
    @setEvalBranchQuota(2000);
    var declarations: [params.len]clap.Param(Option) = undefined;
    for (params, 0..) |param, i| declarations[i] = .{
        .id = if (param.names.long) |name| std.meta.stringToEnum(Option, name).? else .file,
        .names = param.names,
        .takes_value = param.takes_value,
    };
    break :blk declarations;
};

pub fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: huak run FILE.huak [OPTIONS]
        \\       huak watch FILE.huak [OPTIONS] [--json]
        \\       huak check FILE.huak [--libtypst PATH]
        \\       huak disassemble FILE.huak [--libtypst PATH]
        \\       huak --help
        \\
        \\Commands and global options:
        \\
    );
    try clap.help(writer, clap.Help, &main_params, .{});
    try writer.writeAll("\nScript options (parameters, outputs, jobs and fonts require run or watch):\n");
    try clap.help(writer, clap.Help, &params, .{});
}

/// Returned strings borrow args; owned parameter/font/output lists use allocator.
/// zig-clap handles options, assignments and --. The remaining checks express
/// huak's command, duplicate and script-parameter rules.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diagnostic: *?[]const u8) !Options {
    diagnostic.* = null;
    var iterator: clap.args.SliceIterator = .{ .args = args };
    var detail: clap.Diagnostic = .{};
    var main_parser: clap.streaming.Clap(clap.Help, clap.args.SliceIterator) = .{ .params = &main_params, .iter = &iterator, .diagnostic = &detail };
    const first = (main_parser.next() catch |err| return clapFailure(allocator, diagnostic, detail, err)) orelse
        return fail(allocator, diagnostic, "expected run, watch, check or disassemble", .{});
    if (first.param.names.long != null) {
        if (args.len != 1) return fail(allocator, diagnostic, "help does not accept other arguments", .{});
        return .{ .command = .help };
    }
    // Subcommand precedes all script options; a leading -- is not a command.
    if (iterator.index != 1) return fail(allocator, diagnostic, "unknown command '{s}'", .{args[0]});
    const command = clap.parsers.enumeration(Command)(first.value.?) catch
        return fail(allocator, diagnostic, "unknown command '{s}'", .{first.value.?});
    if (command == .help) {
        if (args.len != 1) return fail(allocator, diagnostic, "help does not accept other arguments", .{});
        return .{ .command = .help };
    }
    var result: Options = .{ .command = command };
    var parameters: std.array_list.Managed(Parameter) = .init(allocator);
    errdefer parameters.deinit();
    var fonts: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer fonts.deinit();
    var font_dirs: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer font_dirs.deinit();
    var outputs: std.array_list.Managed(Output) = .init(allocator);
    errdefer outputs.deinit();
    var parser: clap.streaming.Clap(Option, clap.args.SliceIterator) = .{ .params = &option_params, .iter = &iterator, .diagnostic = &detail };
    while (true) {
        const before = iterator.index;
        const arg = (parser.next() catch |err| return clapFailure(allocator, diagnostic, detail, err)) orelse break;
        const option = arg.param.id;
        const name = arg.param.names.long orelse "";
        const value = arg.value orelse "";
        if (option == .json and command != .watch)
            return fail(allocator, diagnostic, "--json is only valid with watch", .{});
        if (option != .file and command != .run and command != .watch and option != .libtypst)
            return fail(allocator, diagnostic, "--{s} is only valid with run or watch", .{name});
        // A separate value beginning with -- is a misplaced option. Attached
        // --name=--value remains literal, and -- may precede any file path.
        if (option != .file and iterator.index - before > 1 and std.mem.startsWith(u8, value, "--"))
            return fail(allocator, diagnostic, "missing value for '--{s}'", .{name});
        switch (option) {
            .json => {
                if (result.json) return fail(allocator, diagnostic, "duplicate option '--json'", .{});
                result.json = true;
            },
            .file => {
                if (result.script != null) return fail(allocator, diagnostic, "unexpected positional argument '{s}'", .{value});
                if (value.len == 0) return fail(allocator, diagnostic, "script path must not be empty", .{});
                result.script = value;
            },
            .@"no-bundled-fonts" => {
                if (!result.bundled_fonts) return fail(allocator, diagnostic, "duplicate option '--{s}'", .{name});
                result.bundled_fonts = false;
            },
            .@"system-fonts" => {
                if (result.system_fonts) return fail(allocator, diagnostic, "duplicate option '--{s}'", .{name});
                result.system_fonts = true;
            },
            .param => {
                const at = std.mem.indexOfScalar(u8, value, '=') orelse return fail(allocator, diagnostic, "parameter must use NAME=VALUE: '{s}'", .{value});
                if (at == 0) return fail(allocator, diagnostic, "parameter name must not be empty", .{});
                const parameter: Parameter = .{ .name = value[0..at], .value = value[at + 1 ..] };
                for (parameters.items) |previous| if (std.mem.eql(u8, previous.name, parameter.name))
                    return fail(allocator, diagnostic, "duplicate parameter '{s}'", .{parameter.name});
                try parameters.append(parameter);
            },
            .output => {
                if (value.len == 0) return fail(allocator, diagnostic, "empty value for '--output'", .{});
                const output: Output = if (std.mem.indexOfScalar(u8, value, '=')) |at|
                    .{ .name = value[0..at], .path = value[at + 1 ..] }
                else
                    .{ .name = "default", .path = value };
                if (!identifier(output.name)) return fail(allocator, diagnostic, "output name must be an identifier: '{s}'", .{output.name});
                if (output.path.len == 0) return fail(allocator, diagnostic, "output path must not be empty", .{});
                if (!std.mem.endsWith(u8, output.path, ".svg") and !std.mem.endsWith(u8, output.path, ".pdf"))
                    return fail(allocator, diagnostic, "output must end in .svg or .pdf: '{s}'", .{output.path});
                for (outputs.items) |previous| if (std.mem.eql(u8, previous.path, output.path))
                    return fail(allocator, diagnostic, "duplicate output path '{s}'", .{output.path});
                try outputs.append(output);
            },
            .jobs => {
                if (result.jobs != null) return fail(allocator, diagnostic, "duplicate option '--{s}'", .{name});
                const jobs = std.fmt.parseInt(usize, value, 10) catch
                    return fail(allocator, diagnostic, "jobs must be a positive integer: '{s}'", .{value});
                if (jobs == 0) return fail(allocator, diagnostic, "jobs must be a positive integer: '{s}'", .{value});
                result.jobs = jobs;
            },
            .libtypst => {
                if (value.len == 0) return fail(allocator, diagnostic, "empty value for '--{s}'", .{name});
                if (result.library != null) return fail(allocator, diagnostic, "duplicate option '--{s}'", .{name});
                result.library = value;
            },
            .font => {
                if (value.len == 0) return fail(allocator, diagnostic, "empty value for '--{s}'", .{name});
                try fonts.append(value);
            },
            .@"font-path" => {
                if (value.len == 0) return fail(allocator, diagnostic, "empty value for '--{s}'", .{name});
                try font_dirs.append(value);
            },
        }
    }
    if (result.script == null) return fail(allocator, diagnostic, "missing script path", .{});
    result.parameters = try parameters.toOwnedSlice();
    errdefer allocator.free(result.parameters);
    result.fonts = try fonts.toOwnedSlice();
    errdefer allocator.free(result.fonts);
    result.font_dirs = try font_dirs.toOwnedSlice();
    errdefer allocator.free(result.font_dirs);
    result.outputs = try outputs.toOwnedSlice();
    return result;
}

fn identifier(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn clapFailure(allocator: std.mem.Allocator, diagnostic: *?[]const u8, detail: clap.Diagnostic, err: anyerror) error{ OutOfMemory, InvalidArguments } {
    const name = detail.name.longest();
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => fail(allocator, diagnostic, "unknown option '{s}{s}'", .{ name.kind.prefix(), detail.arg }),
        error.MissingValue => fail(allocator, diagnostic, "missing value for '{s}{s}'", .{ name.kind.prefix(), name.name }),
        error.DoesntTakeValue => fail(allocator, diagnostic, "{s}{s} does not accept a value", .{ name.kind.prefix(), name.name }),
        else => fail(allocator, diagnostic, "argument parsing failed: {s}", .{@errorName(err)}),
    };
}

fn fail(allocator: std.mem.Allocator, diagnostic: *?[]const u8, comptime format: []const u8, args: anytype) error{ OutOfMemory, InvalidArguments } {
    diagnostic.* = try std.fmt.allocPrint(allocator, format, args);
    return error.InvalidArguments;
}

fn rejected(args: []const []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), args, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?, expected) != null);
}

test "run flags preserve literal strings and repeated font paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    const options = try parse(arena.allocator(), &.{ "run", "drawing.huak", "--param", "count=200", "--param=title=\"); panic(\"x\")", "--param", "empty=", "--output", "out.pdf", "--output=detail=more=detail.svg", "--output=detail=other.pdf", "--libtypst=custom.dylib", "--font", "one.ttf", "--font=two.otf", "--font-path", "fonts", "--font-path=more fonts", "--system-fonts", "--no-bundled-fonts" }, &diagnostic);
    try std.testing.expectEqual(Command.run, options.command);
    try std.testing.expectEqualStrings("drawing.huak", options.script.?);
    try std.testing.expectEqualStrings("custom.dylib", options.library.?);
    try std.testing.expectEqual(@as(usize, 3), options.outputs.len);
    try std.testing.expectEqualStrings("default", options.outputs[0].name);
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
    const options = try parse(arena.allocator(), &.{ "watch", "--json", "--output", "default=preview.svg", "--param", "count=3", "drawing.huak", "--font", "custom.otf", "-j2" }, &diagnostic);
    try std.testing.expectEqual(Command.watch, options.command);
    try std.testing.expect(options.json);
    try std.testing.expectEqualStrings("drawing.huak", options.script.?);
    try std.testing.expectEqualStrings("default", options.outputs[0].name);
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
    const options = try parse(allocator, &.{ "run", "--libtypst=--syntax-library", "--font=--font.ttf", "--param=label=--literal", "--output=--drawing.svg", "--", "-drawing.huak" }, &diagnostic);
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
    const help = try parse(arena.allocator(), &.{"--help"}, &diagnostic);
    try std.testing.expectEqual(Command.help, help.command);
    const check = try parse(arena.allocator(), &.{ "check", "--libtypst", "lib.so", "a.huak" }, &diagnostic);
    try std.testing.expectEqual(Command.check, check.command);
    const disassemble = try parse(arena.allocator(), &.{ "disassemble", "--", "-a.huak" }, &diagnostic);
    try std.testing.expectEqual(Command.disassemble, disassemble.command);
    try std.testing.expectEqualStrings("-a.huak", disassemble.script.?);
}

test "parallel output jobs use clap long and short options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?[]const u8 = null;
    const automatic = try parse(arena.allocator(), &.{ "run", "a.huak" }, &diagnostic);
    try std.testing.expect(automatic.jobs == null);
    for ([_][]const []const u8{
        &.{ "run", "a.huak", "--jobs", "3" },
        &.{ "run", "--jobs=3", "a.huak" },
        &.{ "run", "a.huak", "-j", "3" },
        &.{ "run", "a.huak", "-j3" },
        &.{ "run", "a.huak", "--jobs=+3" },
    }) |args| {
        const options = try parse(arena.allocator(), args, &diagnostic);
        try std.testing.expectEqual(@as(?usize, 3), options.jobs);
        try std.testing.expect(diagnostic == null);
    }
    const serial = try parse(arena.allocator(), &.{ "run", "a.huak", "--jobs=1" }, &diagnostic);
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
