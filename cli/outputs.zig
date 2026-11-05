//! Bounded output scheduling and filesystem writes after script execution.
//! The batch owns retained pictures/text; workers own only export scratch space.
const std = @import("std");
const huak = @import("huak");
const typst = @import("libtypst");
const Output = @import("options.zig").Output;
const OutputBatch = huak.language.OutputBatch;
const Format = huak.render.Format;
const Report = @import("Report.zig");
pub const Publication = enum { in_place, atomic };

const Failure = struct {
    stage: enum { render, write },
    cause: anyerror,
    diagnostic: ?typst.Buffer = null,

    fn deinit(self: *Failure) void {
        if (self.diagnostic) |*message| message.deinit();
    }
};
const Result = union(enum) {
    pending,
    written: usize,
    failed: Failure,
};

/// Every claimed batch entry is released after its output finishes. Unclaimed
/// entries on failure remain owned by batch and are released by Batch.deinit.
/// No task retains an output buffer after writing. All started tasks complete
/// before this function returns, including cancellation and startup failures.
pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    batch: *OutputBatch,
    requested: []const Output,
    jobs: ?usize,
    script_path: []const u8,
    publication: Publication,
    report: *Report,
) !void {
    if (batch.len() != requested.len) return error.InvalidOutputBatch;
    if (requested.len == 0) return;
    // Validate every requested format before any file is opened. In particular,
    // a later animated PDF must not leave earlier outputs from this invocation.
    for (requested, 0..) |output, index| {
        batch.validate(index, format(output.path)) catch |err| {
            reportRenderFailure(script_path, output, err, null, report);
            return error.Reported;
        };
    }
    const results = try allocator.alloc(Result, requested.len);
    defer allocator.free(results);
    @memset(results, .pending);
    defer for (results) |*result| switch (result.*) {
        .failed => |*failure| failure.deinit(),
        else => {},
    };
    var shared: Shared = .{ .io = io, .batch = batch, .requested = requested, .results = results, .publication = publication };
    try huak.worker.run(io, requested.len, jobs, &shared, Shared.one);
    var failed = false;
    // Reporting stays deterministic even though completion order is arbitrary.
    for (requested, results) |output, result| switch (result) {
        .pending => {},
        .written => |length| std.debug.print("wrote {s} ({d} bytes)\n", .{ output.path, length }),
        .failed => |failure| {
            failed = true;
            switch (failure.stage) {
                .render => reportRenderFailure(script_path, output, failure.cause, failure.diagnostic, report),
                .write => report.failure("huak: cannot write '{s}': {s}", .{ output.path, @errorName(failure.cause) }),
            }
        },
    };
    if (failed) return error.Reported;
}

const Shared = struct {
    io: std.Io,
    batch: *OutputBatch,
    requested: []const Output,
    results: []Result,
    publication: Publication,
    fn one(self: *Shared, index: usize) bool {
        // A failed result already owns its diagnostic independently. Clear the
        // completed task's convenience slot before this I/O thread is reused.
        defer self.batch.library.clearError();
        defer self.batch.release(index);
        // A fresh arena per output returns large temporary allocations rather
        // than retaining the largest export for the rest of a long batch.
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const output = self.requested[index];
        var diagnostic: ?typst.Buffer = null;
        var rendered = self.batch.render(scratch.allocator(), index, format(output.path), &diagnostic) catch |err| {
            self.results[index] = .{ .failed = .{ .stage = .render, .cause = err, .diagnostic = diagnostic } };
            return false;
        };
        defer rendered.deinit();
        // A successful render must not retain a recovered native diagnostic.
        if (diagnostic) |*message| message.deinit();
        publish(self.io, output.path, rendered.bytes(), self.publication) catch |err| {
            self.results[index] = .{ .failed = .{ .stage = .write, .cause = err } };
            return false;
        };
        self.results[index] = .{ .written = rendered.bytes().len };
        return true;
    }
};

fn publish(io: std.Io, path: []const u8, bytes: []const u8, publication: Publication) !void {
    const directory = std.Io.Dir.cwd();
    // Ordinary runs retain their existing symlink/hardlink write semantics.
    if (publication == .in_place) return directory.writeFile(io, .{ .sub_path = path, .data = bytes });
    // Watch readers can keep the previous inode open while a rebuild publishes
    // its replacement. A failed write never exposes a partially written file.
    var file = try directory.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn format(path: []const u8) Format {
    return if (std.mem.endsWith(u8, path, ".pdf")) .pdf else .svg;
}

fn reportRenderFailure(path: []const u8, output: Output, cause: anyerror, diagnostic: ?typst.Buffer, report: *Report) void {
    report.failure("{s}: cannot render export '{s}' to '{s}': {s}", .{ path, output.name, output.path, @errorName(cause) });
    if (diagnostic) |message| {
        const bytes = message.bytes();
        if (bytes.len != 0) {
            report.remember("{s}: cannot render export '{s}': {s}\n{s}", .{ path, output.name, @errorName(cause), bytes });
            std.debug.print("libtypst: {s}\n", .{bytes});
        }
    }
}
