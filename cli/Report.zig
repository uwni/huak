//! Source locations and VM/native failures presented by the command-line host.
const std = @import("std");
const language = @import("huak").language;
const bundles = @import("huak").tooling.diagnostics;

/// A build owns its concise message; terminal diagnostics retain their full
/// source locations and runtime notes. Watch can expose the same failure in a
/// JSON event without capturing or redirecting process-wide stderr.
const Report = @This();

allocator: std.mem.Allocator,
io: std.Io,
message: ?[]const u8 = null,

pub fn remember(self: *Report, comptime format: []const u8, args: anytype) void {
    self.message = std.fmt.allocPrint(self.allocator, format, args) catch "diagnostic allocation failed";
}

pub fn fail(self: *Report, comptime format: []const u8, args: anytype) error{Reported} {
    self.failure(format, args);
    return error.Reported;
}

pub fn failure(self: *Report, comptime format: []const u8, args: anytype) void {
    self.remember(format, args);
    std.debug.print(format ++ "\n", args);
}

pub fn print(self: *Report, path: []const u8, source: []const u8, detail: *const language.compiler.Diagnostic) void {
    const position = detail.position(source);
    self.remember("{s}:{d}:{d}: {s}", .{ detail.fileName() orelse path, position.line, position.column, detail.text() });
    bundles.report(self.io, self.allocator, path, source, detail);
}

pub fn machineFailure(self: *Report, machine: *const language.Machine, path: []const u8, source: []const u8, cause: anyerror) anyerror {
    if (machine.failure) |detail| {
        const position = detail.diagnostic.position(source);
        self.remember("{s}:{d}:{d}: {s}{s}{s}", .{ detail.diagnostic.fileName() orelse path, position.line, position.column, detail.diagnostic.text(), if (detail.native_message.len == 0) "" else "\n", detail.native_message });
        var bundle = bundles.fromRuntime(self.allocator, path, source, &detail, machine.program.modules) catch {
            self.print(path, source, &detail.diagnostic);
            if (detail.native_message.len != 0) std.debug.print("{s}\n", .{detail.native_message});
            return error.Reported;
        };
        defer bundle.deinit(self.allocator);
        bundle.renderToStderr(self.io, .{}, .off) catch self.print(path, source, &detail.diagnostic);
        return error.Reported;
    }
    return cause;
}
