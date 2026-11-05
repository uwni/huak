//! Final diagnostic aggregation uses Zig's standard owned ErrorBundle. Language
//! stages retain their allocation-free first-error carrier; applications choose
//! how to render or expose the resulting structured bundle.
const std = @import("std");
const source = @import("../language/source.zig");
const bytecode = @import("../language/bytecode.zig");
const Machine = @import("../language/Machine.zig");

pub fn fromDiagnostic(allocator: std.mem.Allocator, path: []const u8, text: []const u8, detail: *const source.Diagnostic) !std.zig.ErrorBundle {
    var wip = try std.zig.ErrorBundle.Wip.init(allocator);
    defer wip.deinit();
    try wip.addRootErrorMessage(.{
        .msg = try addString(&wip, detail.text()),
        .src_loc = try diagnosticLocation(&wip, path, text, detail),
    });
    return wip.toOwnedBundle("");
}

pub fn fromRuntime(allocator: std.mem.Allocator, path: []const u8, text: []const u8, detail: *const Machine.RuntimeDiagnostic, modules: []const bytecode.Module) !std.zig.ErrorBundle {
    var wip = try std.zig.ErrorBundle.Wip.init(allocator);
    defer wip.deinit();
    const primary_path = detail.diagnostic.fileName() orelse path;
    var primary_text: ?[]const u8 = if (std.mem.eql(u8, primary_path, path)) text else null;
    for (modules) |module| if (std.mem.eql(u8, module.name, primary_path)) {
        primary_text = module.source_text;
        break;
    };
    const note_count = detail.trace.len + @intFromBool(detail.native_message.len != 0);
    try wip.addRootErrorMessage(.{
        .msg = try addString(&wip, detail.diagnostic.text()),
        .src_loc = try location(&wip, primary_path, primary_text, detail.diagnostic.span, detail.diagnostic.origin),
        .notes_len = @intCast(note_count),
    });
    const notes = try wip.reserveNotes(@intCast(note_count));
    var next: usize = notes;
    if (detail.native_message.len != 0) {
        const note = try wip.addErrorMessage(.{ .msg = try addString(&wip, detail.native_message) });
        wip.extra.items[next] = @backingInt(note);
        next += 1;
    }
    for (detail.trace) |entry| {
        const file = if (entry.module < modules.len) modules[entry.module].name else path;
        const origin = if (entry.module < modules.len) modules[entry.module].source_text else text;
        const note = try wip.addErrorMessage(.{
            .msg = try wip.printString("at {s}", .{entry.function}),
            .src_loc = try location(&wip, file, origin, entry.span, null),
        });
        // addErrorMessage and its location can reallocate extra; retain indices.
        wip.extra.items[next] = @backingInt(note);
        next += 1;
    }
    return wip.toOwnedBundle("");
}

/// Allocation or terminal failure retains a concise, allocation-free report.
pub fn report(io: std.Io, allocator: std.mem.Allocator, path: []const u8, text: []const u8, detail: *const source.Diagnostic) void {
    var bundle = fromDiagnostic(allocator, path, text, detail) catch {
        fallback(path, text, detail);
        return;
    };
    defer bundle.deinit(allocator);
    bundle.renderToStderr(io, .{}, .off) catch fallback(path, text, detail);
}

fn fallback(path: []const u8, text: []const u8, detail: *const source.Diagnostic) void {
    const position = detail.position(text);
    std.debug.print("{s}:{d}:{d}: {s}\n", .{ detail.fileName() orelse path, position.line, position.column, detail.text() });
}

fn diagnosticLocation(wip: *std.zig.ErrorBundle.Wip, path: []const u8, text: []const u8, detail: *const source.Diagnostic) !std.zig.ErrorBundle.SourceLocationIndex {
    const file = detail.fileName() orelse path;
    return location(wip, file, if (std.mem.eql(u8, file, path)) text else null, detail.span, detail.origin);
}

fn location(wip: *std.zig.ErrorBundle.Wip, path: []const u8, text: ?[]const u8, span: source.Span, origin: ?source.Diagnostic.Position) !std.zig.ErrorBundle.SourceLocationIndex {
    const start = if (text) |content| @min(span.start, content.len) else span.start;
    const found = if (text) |content| std.zig.findLineColumn(content, start) else null;
    const line = if (origin) |p| p.line -| 1 else if (found) |p| p.line else 0;
    const column = if (origin) |p| p.column -| 1 else if (found) |p| p.column else 0;
    const end = if (found) |p| @max(start, @min(span.end, start - p.column + p.source_line.len)) else @max(start, span.end);
    return wip.addSourceLocation(.{
        .src_path = try addString(wip, path),
        .line = narrow(line),
        .column = narrow(column),
        .span_start = narrow(start),
        .span_main = narrow(start),
        .span_end = narrow(end),
        .source_line = if (found) |p| try wip.addString(p.source_line) else 0,
    });
}

fn narrow(value: usize) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn addString(wip: *std.zig.ErrorBundle.Wip, text: []const u8) !std.zig.ErrorBundle.String {
    // ErrorBundle strings are NUL-terminated. Escape a literal NUL with the
    // standard formatter rather than silently losing the rest of a message.
    if (std.mem.indexOfScalar(u8, text, 0) != null) return wip.printString("{f}", .{std.zig.fmtString(text)});
    return wip.addString(text);
}

test "standard bundles own source snapshots and retain complete native notes" {
    const allocator = std.testing.allocator;
    var bundle: std.zig.ErrorBundle = undefined;
    {
        const path = try allocator.dupe(u8, "/project/figure.huak");
        defer allocator.free(path);
        const text = try allocator.dupe(u8, "first\nproblem()\n");
        defer allocator.free(text);
        const payload = try allocator.alloc(u8, 8192);
        defer allocator.free(payload);
        @memset(payload, 'n');
        var detail: Machine.RuntimeDiagnostic = .{
            .diagnostic = source.Diagnostic.init(.{ .start = 6, .end = 13 }, "native operation failed", .{}),
            .native_message = payload,
            .trace = &.{.{ .function = "figure", .span = .{ .start = 6, .end = 13 }, .module = 0 }},
        };
        detail.diagnostic.setSource(path, text);
        bundle = try fromRuntime(allocator, path, text, &detail, &.{.{ .name = path, .source_text = text, .entry = 0, .exports = &.{} }});
    }
    defer bundle.deinit(allocator);
    const root = bundle.getMessages()[0];
    const message = bundle.getErrorMessage(root);
    const loc = bundle.getSourceLocation(message.src_loc);
    try std.testing.expectEqualStrings("/project/figure.huak", bundle.nullTerminatedString(loc.src_path));
    try std.testing.expectEqualStrings("problem()", bundle.nullTerminatedString(loc.source_line));
    try std.testing.expectEqual(@as(u32, 1), loc.line);
    try std.testing.expectEqual(@as(u32, 0), loc.column);
    const notes = bundle.getNotes(root);
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqual(@as(usize, 8192), bundle.nullTerminatedString(bundle.getErrorMessage(notes[0]).msg).len);
    try std.testing.expectEqualStrings("at figure", bundle.nullTerminatedString(bundle.getErrorMessage(notes[1]).msg));
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try bundle.renderToWriter(.{}, &rendered.writer);
    try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "/project/figure.huak:2:1: error: native operation failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "note: at figure") != null);
    try std.testing.expect(rendered.written().len > 8192);
}

test "import errors retain their location without borrowing a released module" {
    var detail = source.Diagnostic.init(.{ .start = 10, .end = 12 }, "unknown value", .{});
    detail.setSource("/project/dependency.huak", "first\n    missing");
    var bundle = try fromDiagnostic(std.testing.allocator, "/project/root.huak", "import unrelated", &detail);
    defer bundle.deinit(std.testing.allocator);
    const loc = bundle.getSourceLocation(bundle.getErrorMessage(bundle.getMessages()[0]).src_loc);
    try std.testing.expectEqualStrings("/project/dependency.huak", bundle.nullTerminatedString(loc.src_path));
    try std.testing.expectEqual(@as(u32, 1), loc.line);
    try std.testing.expectEqual(@as(u32, 4), loc.column);
    try std.testing.expectEqual(@as(u32, 0), loc.source_line);
}

test "embedded NUL in native diagnostics does not truncate later text" {
    const detail: Machine.RuntimeDiagnostic = .{
        .diagnostic = source.Diagnostic.init(.{ .start = 0, .end = 1 }, "failure", .{}),
        .native_message = "before\x00after",
    };
    var bundle = try fromRuntime(std.testing.allocator, "figure.huak", "x", &detail, &.{});
    defer bundle.deinit(std.testing.allocator);
    const note = bundle.getNotes(bundle.getMessages()[0])[0];
    try std.testing.expect(std.mem.indexOf(u8, bundle.nullTerminatedString(bundle.getErrorMessage(note).msg), "after") != null);
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    // ErrorBundle compaction may remap in place or fall back to allocation.
    // Force the fallback with the standard test allocator so every injected
    // allocation index follows the same path regardless of heap placement.
    var allocation_only = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const stable_allocator = allocation_only.allocator();
    var payload: [8192]u8 = @splat('n');
    const text = "first\nproblem()\n";
    const detail: Machine.RuntimeDiagnostic = .{
        .diagnostic = source.Diagnostic.init(.{ .start = 6, .end = 13 }, "native operation failed", .{}),
        .native_message = &payload,
        .trace = &.{
            .{ .function = "figure", .span = .{ .start = 6, .end = 13 } },
            .{ .function = "caller", .span = .{ .start = 0, .end = 5 } },
        },
    };
    var bundle = try fromRuntime(stable_allocator, "figure.huak", text, &detail, &.{});
    defer bundle.deinit(stable_allocator);
    try std.testing.expectEqual(@as(u32, 1), bundle.errorMessageCount());
    try std.testing.expectEqual(@as(usize, 3), bundle.getNotes(bundle.getMessages()[0]).len);
}

test "all diagnostic aggregation allocation failures release their temporary ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
