//! A worker owns one engine. Each submission owns its program, VM and scene.
//! Result bytes can be read until the next call to huak_render.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const lang = huak.language;
const diagnostics = huak.tooling.diagnostics;
const allocator = std.heap.c_allocator;
const Files = std.json.ArrayHashMap([]const u8);
const Catalog = struct { files: Files, entries: []const []const u8 };

var library = typst.Library.linked();
var input: []u8 = &.{};
var examples: ?std.json.Parsed(Catalog) = null;
var output: ?huak.render.Output = null;
var report: std.Io.Writer.Allocating = .init(allocator);
var cause: []const u8 = "";

/// The worker writes exactly len UTF-8 bytes here before calling huak_render.
export fn huak_input(len: usize) ?[*]u8 {
    input = allocator.realloc(input, len) catch return null;
    return input.ptr;
}

/// Keep imported example sources across renders. The input buffer is reused.
export fn huak_set_files() bool {
    const parsed = std.json.parseFromSlice(Catalog, allocator, input, .{ .allocate = .alloc_always }) catch return false;
    if (examples) |*previous| previous.deinit();
    examples = parsed;
    return true;
}

fn resolveFile(context: *anyopaque, arena: std.mem.Allocator, importer: []const u8, path: []const u8) !lang.compiler.ResolvedSource {
    const catalog: *const Files = @ptrCast(@alignCast(context));
    const name = try std.fs.path.resolveAllocPosix(arena, &.{ std.fs.path.dirnamePosix(importer) orelse ".", path });
    return .{ .name = name, .source = catalog.map.get(name) orelse return error.FileNotFound };
}

/// The input starts with filename_len bytes of relative path, followed by the edited source.
export fn huak_render(filename_len: usize) bool {
    if (output) |*previous| previous.deinit();
    output = null;
    report.clearRetainingCapacity();
    cause = "";
    if (filename_len > input.len) {
        cause = "Invalid filename length";
        return false;
    }
    const filename = if (filename_len == 0) "playground.huak" else input[0..filename_len];
    output = render(filename, input[filename_len..]) catch |err| {
        cause = @errorName(err);
        return false;
    };
    return true;
}

fn render(filename: []const u8, source: []const u8) !huak.render.Output {
    var detail: ?lang.compiler.Diagnostic = null;
    var program = lang.compiler.compile(allocator, source, filename, .{
        .source_parser = .{ .ptr = &library, .vtable = &.{ .block = sourceBlock } },
        .import_resolver = if (examples) |*catalog| .{ .ptr = &catalog.value.files, .vtable = &.{ .resolve = resolveFile } } else null,
    }, &detail) catch |err| {
        if (detail) |*d| try writeReport(diagnostics.fromDiagnostic(allocator, filename, source, d));
        return err;
    };
    defer program.deinit();
    const selected = program.outputNamed("default") orelse {
        try report.writer.writeAll("Declare a default picture to preview.");
        return error.MissingDefaultPicture;
    };

    var machine = try lang.Machine.init(allocator, &program, .{}, .{});
    defer machine.deinit();
    errdefer if (machine.failure) |*failure| writeReport(diagnostics.fromRuntime(allocator, filename, source, failure, program.modules)) catch {};
    try machine.prepareParameters(&.{});
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var runtime = try lang.Runtime.init(allocator, allocator, &library, .{
        .inputs = try lang.Runtime.Options.scriptInputs(scratch.allocator(), &machine),
    });
    defer runtime.deinit();
    machine.host = runtime.host();
    _ = try machine.execute(&.{});
    const value = machine.getGlobalAt(selected.global) orelse return error.MissingDefaultPicture;
    if (value.valueType() != .picture) return error.ExpectedPicture;
    return runtime.render(value, .svg) catch |err| {
        try report.writer.writeAll(runtime.nativeDiagnostic());
        return err;
    };
}

fn writeReport(bundle: anyerror!std.zig.ErrorBundle) !void {
    var owned = try bundle;
    defer owned.deinit(allocator);
    try owned.renderToWriter(.{}, &report.writer);
}

fn sourceBlock(ctx: *anyopaque, source: []const u8) !usize {
    const backend: *typst.Library = @ptrCast(@alignCast(ctx));
    return backend.sourceBlock(source);
}

fn result() []const u8 {
    if (output) |*svg| return svg.bytes();
    return if (report.written().len != 0) report.written() else cause;
}

export fn huak_result() [*]const u8 {
    return result().ptr;
}

export fn huak_result_len() usize {
    return result().len;
}

test "formula preview survives a Typst diagnostic and renders again in the same instance" {
    const example = @embedFile("site/integral.huak");
    @memcpy(huak_input(example.len).?[0..example.len], example);
    try std.testing.expect(huak_render(0));
    const svg = try std.testing.allocator.dupe(u8, huak_result()[0..huak_result_len()]);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<use") != null);

    const invalid = "value := typ[#missing_playground_variable]\ndefault picture(30, 20)";
    @memcpy(huak_input(invalid.len).?[0..invalid.len], invalid);
    try std.testing.expect(!huak_render(0));
    try std.testing.expect(std.mem.indexOf(u8, huak_result()[0..huak_result_len()], "missing_playground_variable") != null);

    @memcpy(huak_input(example.len).?[0..example.len], example);
    try std.testing.expect(huak_render(0));
    try std.testing.expectEqualStrings(svg, huak_result()[0..huak_result_len()]);
}

test "all published examples render through the worker interface" {
    const json = @embedFile("example-catalog");
    @memcpy(huak_input(json.len).?[0..json.len], json);
    try std.testing.expect(huak_set_files());
    const catalog = examples.?.value;
    try std.testing.expect(catalog.entries.len > 0);
    if (catalog.files.map.get("space/torus.huak")) |torus| {
        const start = std.Io.Clock.awake.now(std.testing.io);
        @memcpy(huak_input(torus.len).?[0..torus.len], torus);
        try std.testing.expect(huak_render(0));
        const elapsed = start.durationTo(std.Io.Clock.awake.now(std.testing.io));
        std.debug.print("first torus script to SVG: {d} ms\n", .{elapsed.toMilliseconds()});
        const contracts = @import("space_contracts");
        inline for (contracts.names) |name| {
            const contract = contracts.source(name);
            @memcpy(huak_input(contract.len).?[0..contract.len], contract);
            if (!huak_render(0)) {
                std.debug.print("{s}: {s}\n", .{ name, result() });
                return error.ProjectionContractFailed;
            }
        }
    }
    for (catalog.entries) |path| {
        const source = catalog.files.map.get(path).?;
        const buffer = huak_input(path.len + source.len).?[0 .. path.len + source.len];
        @memcpy(buffer[0..path.len], path);
        @memcpy(buffer[path.len..], source);
        if (!huak_render(path.len)) {
            std.debug.print("{s}: {s}\n", .{ path, result() });
            return error.ExampleRenderFailed;
        }
        try std.testing.expect(std.mem.indexOf(u8, result(), "<svg") != null);
    }
}
