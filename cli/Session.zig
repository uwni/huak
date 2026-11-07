//! Desktop backends belong to the session. Each build releases its VM and
//! outputs before the next watch iteration or session shutdown.
const std = @import("std");
const huak = @import("huak");
const typst = @import("libtypst");
const flags = @import("options.zig");
const disassemble = @import("disassemble.zig");
const execution = @import("execution.zig");
const outputs = @import("outputs.zig");
const output_paths = @import("output_paths.zig");
const Report = @import("Report.zig");

const Session = @This();

allocator: std.mem.Allocator,
io: std.Io,
library_path: []const u8,
typesetter: typst.Error!typst.Library,
projection: ?huak.Projection,
options: flags.Options,

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: flags.Options) Session {
    const library_path = options.library orelse @import("host_options").library_path;
    const backend_name = switch (@import("builtin").os.tag) {
        .macos => "@rpath/libhuak_space.dylib",
        .linux => "libhuak_space.so",
        else => unreachable,
    };
    const projection: ?huak.Projection = huak.Projection.open(backend_name) catch |err| unavailable_backend: {
        if (err != error.LibraryNotFound) std.debug.print("huak: incompatible 3D projection library '{s}'\n", .{backend_name});
        break :unavailable_backend null;
    };
    return .{
        .allocator = allocator,
        .io = io,
        .library_path = library_path,
        .typesetter = typst.Library.open(library_path),
        .projection = projection,
        .options = options,
    };
}

pub fn deinit(self: *Session) void {
    if (self.typesetter) |*library| library.deinit() else |_| {}
    if (self.projection) |*backend| backend.close();
    self.* = undefined;
}

pub fn build(self: *Session, report: *Report, observer: ?huak.tooling.Frontend.Observer) !void {
    var destinations = try output_paths.validate(self.io, report.allocator, self.options.outputs, report);
    defer destinations.deinit(report.allocator);
    const path = self.options.script.?;
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, report.allocator) catch |err|
        return report.fail("{s}: cannot read script: {s}", .{ path, @errorName(err) });
    const source = std.Io.Dir.cwd().readFileAlloc(self.io, canonical, report.allocator, .unlimited) catch |err|
        return report.fail("{s}: cannot read script: {s}", .{ path, @errorName(err) });
    const frontend: huak.tooling.Frontend = .{
        .allocator = self.allocator,
        .io = self.io,
        .source_parser = if (self.typesetter) |*library| .init(library) else |err| err,
        .dependency_observer = observer,
    };
    var diagnostic: ?huak.language.compiler.Diagnostic = null;
    if (self.options.command == .check) {
        return frontend.check(source, canonical, &diagnostic) catch |err| self.reportCompilationFailure(path, source, &diagnostic, err, report);
    }
    // The bytecode and VM are released before the output workers start.
    var batch = evaluate: {
        var program = frontend.compile(source, canonical, &diagnostic) catch |err| return self.reportCompilationFailure(path, source, &diagnostic, err, report);
        defer program.deinit();
        switch (self.options.command) {
            .disassemble => {
                var buffer: [4096]u8 = undefined;
                var writer = std.Io.File.stdout().writerStreaming(self.io, &buffer);
                try disassemble.write(&program, &writer.interface);
                try writer.interface.flush();
                return;
            },
            .run, .watch => {},
            .check, .help => unreachable,
        }
        for (program.modules) |mod| if (std.fs.path.isAbsolute(mod.name)) try output_paths.checkInput(self.io, &destinations, mod.name, report);
        for (self.options.fonts) |font| try output_paths.checkInput(self.io, &destinations, font, report);
        const library = if (self.typesetter) |*lib| lib else |err| return self.reportTypesetterLoadFailure(err, report);
        // A library supplied by path can re-export symbols from another image.
        if (self.options.library) |file| try output_paths.checkInput(self.io, &destinations, file, report);
        if (library.image_path) |file| try output_paths.checkInput(self.io, &destinations, file, report);
        if (self.projection) |backend| try output_paths.checkInput(self.io, &destinations, backend.path, report);
        break :evaluate try execution.execute(self.allocator, self.io, .{
            .typst = library,
            .projection = if (self.projection) |backend| backend.vtable else null,
        }, &program, self.options, path, source, report);
    };
    defer batch.deinit();
    const publication: outputs.Publication = if (self.options.command == .watch) .atomic else .in_place;
    try outputs.write(self.io, self.allocator, &batch, self.options.outputs, self.options.jobs, path, publication, report);
}

fn reportTypesetterLoadFailure(self: *const Session, cause: anyerror, report: *Report) error{Reported} {
    return report.fail("huak: cannot load libtypst '{s}': {s}", .{ self.library_path, @errorName(cause) });
}

fn reportCompilationFailure(self: *const Session, path: []const u8, source: []const u8, diagnostic: *const ?huak.language.compiler.Diagnostic, cause: anyerror, report: *Report) anyerror {
    if (diagnostic.*) |*detail| {
        if (detail.cause) |underlying| switch (underlying) {
            .unavailable_source_parser => |err| return self.reportTypesetterLoadFailure(err, report),
            else => {},
        };
        report.print(path, source, detail);
        return error.Reported;
    }
    return cause;
}
