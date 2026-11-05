//! One ordered script execution, ending in an owned output handoff. VM storage,
//! fonts, parameter data and unused geometry are freed before rendering starts.
const std = @import("std");
const huak = @import("huak");
const typst = @import("libtypst");
const language = huak.language;
const flags = @import("options.zig");
const Report = @import("Report.zig");

pub fn execute(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const language.bytecode.Program, options: flags.Options, path: []const u8, source: []const u8, report: *Report) !language.OutputBatch {
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    // Reject unavailable outputs before parameter/font setup or execution.
    const selected = try scratch.alloc(*const language.bytecode.Output, options.outputs.len);
    for (options.outputs, selected) |requested, *selection| {
        const output = program.outputNamed(requested.name) orelse {
            if (std.mem.eql(u8, requested.name, "default")) {
                return report.fail("{s}: no default output; declare 'default <picture>' or select --output NAME=FILE", .{path});
            } else {
                return report.fail("{s}: output '{s}' is not defined", .{ path, requested.name });
            }
        };
        selection.* = output;
    }
    var machine = try language.Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    const overrides = try scratch.alloc(language.Machine.Override, options.parameters.len);
    for (overrides, options.parameters) |*to, from| to.* = .{ .name = from.name, .value = from.value };
    machine.prepareParameters(overrides) catch |err| return report.machineFailure(&machine, path, source, err);
    const inputs = try language.Runtime.Options.scriptInputs(scratch, &machine);
    const fonts = try scratch.alloc(typst.FontSource, options.fonts.len);
    for (fonts, options.fonts) |*font, font_path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, font_path, scratch, .unlimited) catch |err| {
            return report.fail("huak: cannot read font '{s}': {s}", .{ font_path, @errorName(err) });
        };
        font.* = .{ .data = bytes };
    }
    var runtime = try language.Runtime.init(allocator, std.heap.c_allocator, library, .{ .font_sources = fonts, .use_bundled_fonts = options.bundled_fonts, .inputs = inputs });
    defer runtime.deinit();
    machine.host = runtime.host();
    var workers: language.tasks.Executor = .{ .allocator = allocator, .io = io, .runtime = &runtime, .jobs = options.jobs };
    workers.attach(&machine);
    _ = machine.execute(&.{}) catch |err| return report.machineFailure(&machine, path, source, err);
    const printed = runtime.printedText();
    if (printed.len != 0) try (if (options.json) std.Io.File.stderr() else std.Io.File.stdout()).writeStreamingAll(io, printed);
    // Validate all dynamic results before rendering any file.
    const targets = try scratch.alloc(language.types.Value, options.outputs.len);
    for (options.outputs, selected, targets) |requested, output, *target| {
        target.* = machine.getGlobalAt(output.global) orelse {
            const detail = language.compiler.Diagnostic.init(output.span, "output '{s}' is uninitialized", .{requested.name});
            report.print(path, source, &detail);
            return error.Reported;
        };
        if (target.valueType() != .picture) {
            const kind = target.valueType();
            const found = if (kind.recordIndex()) |index| if (index < program.records.len) program.records[index].name else kind.name() else kind.name();
            const detail = language.compiler.Diagnostic.init(output.span, "output '{s}' must be a picture, found {s}", .{ requested.name, found });
            report.print(path, source, &detail);
            return error.Reported;
        }
    }
    return runtime.takeOutputs(targets);
}
