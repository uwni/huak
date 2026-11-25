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
/// The events `watch --json` writes, one JSON object a line, each named by
/// its `event` member.
pub const WatchEvent = enum { build_start, success, @"error" };

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
/// The options, each named as it is given after `--`, and the script file.
pub const Option = enum { param, output, jobs, libtypst, font, @"font-path", @"system-fonts", @"no-bundled-fonts", json, file };
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

/// What the command line takes from the engine: the name of a script's
/// default export, which an output given without a name selects, and the
/// formats it renders, each named by the extension of the files it writes.
pub const Engine = struct { default_output: []const u8, formats: []const []const u8 };

/// The format of `formats` an output file is written in, by its extension.
pub fn formatOf(formats: []const []const u8, path: []const u8) ?usize {
    const extension = std.fs.path.extension(path);
    if (extension.len < 2) return null;
    for (formats, 0..) |format, index| if (std.mem.eql(u8, extension[1..], format)) return index;
    return null;
}

/// The extensions of the formats, written as a list: ".svg or .pdf".
const Extensions = struct {
    formats: []const []const u8,

    pub fn format(self: Extensions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.formats, 0..) |name, index| {
            if (index != 0) try writer.writeAll(if (index + 1 == self.formats.len) " or " else ", ");
            try writer.print(".{s}", .{name});
        }
    }
};

/// Returned strings borrow args; owned parameter/font/output lists use allocator.
/// zig-clap handles options, assignments and --. The remaining checks express
/// huak's command, duplicate and script-parameter rules.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, engine: Engine, diagnostic: *?[]const u8) !Options {
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
                    .{ .name = engine.default_output, .path = value };
                if (!identifier(output.name)) return fail(allocator, diagnostic, "output name must be an identifier: '{s}'", .{output.name});
                if (output.path.len == 0) return fail(allocator, diagnostic, "output path must not be empty", .{});
                if (formatOf(engine.formats, output.path) == null)
                    return fail(allocator, diagnostic, "output must end in {f}: '{s}'", .{ Extensions{ .formats = engine.formats }, output.path });
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

test {
    _ = @import("options_test.zig");
}
