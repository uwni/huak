//! A worker owns one engine. Each submission owns its program, VM and scene.
//! Result bytes can be read until the next call to huak_render.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const lang = huak.language;
const diagnostics = huak.tooling.diagnostics;
const allocator = std.heap.c_allocator;
const filename = "playground.huak";

var library = typst.Library.linked();
var input: []u8 = &.{};
var output: ?huak.render.Output = null;
var report: std.Io.Writer.Allocating = .init(allocator);
var cause: []const u8 = "";

/// The worker writes exactly len UTF-8 bytes here before calling huak_render.
export fn huak_input(len: usize) ?[*]u8 {
    input = allocator.realloc(input, len) catch return null;
    return input.ptr;
}

export fn huak_render() bool {
    if (output) |*previous| previous.deinit();
    output = null;
    report.clearRetainingCapacity();
    cause = "";
    output = render() catch |err| {
        cause = @errorName(err);
        return false;
    };
    return true;
}

fn render() !huak.render.Output {
    var detail: ?lang.compiler.Diagnostic = null;
    var program = lang.compiler.compile(allocator, input, filename, .{
        .source_parser = .{ .ptr = &library, .vtable = &.{ .block = sourceBlock } },
    }, &detail) catch |err| {
        if (detail) |*d| try writeReport(try diagnostics.fromDiagnostic(allocator, filename, input, d));
        return err;
    };
    defer program.deinit();
    const selected = for (program.outputs) |entry| {
        if (std.mem.eql(u8, entry.name, "default")) break entry;
    } else {
        try report.writer.writeAll("Declare a default picture to preview.");
        return error.MissingDefaultPicture;
    };

    var machine = try lang.Machine.init(allocator, &program, .{}, .{});
    defer machine.deinit();
    errdefer if (machine.failure) |*failure| writeRuntimeReport(failure, program.modules) catch {};
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

fn writeRuntimeReport(failure: *const lang.Machine.RuntimeDiagnostic, modules: []const lang.bytecode.Module) !void {
    try writeReport(try diagnostics.fromRuntime(allocator, filename, input, failure, modules));
}

fn writeReport(bundle: std.zig.ErrorBundle) !void {
    var owned = bundle;
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
    try std.testing.expect(huak_render());
    const svg = try std.testing.allocator.dupe(u8, huak_result()[0..huak_result_len()]);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<use") != null);

    const invalid = "value := typ[#missing_playground_variable]\ndefault picture(30, 20)";
    @memcpy(huak_input(invalid.len).?[0..invalid.len], invalid);
    try std.testing.expect(!huak_render());
    try std.testing.expect(std.mem.indexOf(u8, huak_result()[0..huak_result_len()], "missing_playground_variable") != null);

    @memcpy(huak_input(example.len).?[0..example.len], example);
    try std.testing.expect(huak_render());
    try std.testing.expectEqualStrings(svg, huak_result()[0..huak_result_len()]);
}
