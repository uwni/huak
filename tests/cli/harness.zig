//! Process-level acceptance helpers. Script fixtures stay in tests/fixtures/cli.
const std = @import("std");
const xml = @import("xml_parser");
const options = @import("test_options");
const t = std.testing;
pub const Result = std.process.RunResult;
pub const Harness = struct {
    temporary: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    executable: []const u8,
    library: []const u8,
    work: []const u8,
    checks: usize = 0,
    pub fn init() !Harness {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        errdefer arena.deinit();
        var temporary = t.tmpDir(.{});
        errdefer temporary.cleanup();
        const a = arena.allocator();
        const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.executable_path, a);
        const library = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.library_path, a);
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = try temporary.dir.realPath(t.io, &path_buffer);
        const work = try a.dupe(u8, path_buffer[0..n]);
        return .{ .temporary = temporary, .arena = arena, .executable = executable, .library = library, .work = work };
    }
    pub fn deinit(self: *Harness) void {
        self.temporary.cleanup();
        self.arena.deinit();
    }
    pub fn allocator(self: *Harness) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn fmt(self: *Harness, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.allocator(), format, args);
    }
    pub fn path(self: *Harness, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator(), &.{ self.work, relative });
    }
    pub fn script(self: *Harness, name: []const u8, source: []const u8) ![]const u8 {
        const relative = try self.fmt("{s}.huak", .{name});
        if (std.fs.path.dirname(relative)) |parent| try self.temporary.dir.createDirPath(t.io, parent);
        try self.temporary.dir.writeFile(t.io, .{ .sub_path = relative, .data = source });
        return self.path(relative);
    }
    pub fn fixture(self: *Harness, comptime name: []const u8) ![]const u8 {
        return self.script(name, @embedFile("../fixtures/cli/" ++ name ++ ".huak"));
    }
    pub fn write(self: *Harness, path_value: []const u8, bytes: []const u8) !void {
        try self.temporary.dir.writeFile(t.io, .{ .sub_path = path_value, .data = bytes });
    }
    pub fn read(self: *Harness, relative: []const u8) ![]const u8 {
        return self.temporary.dir.readFileAlloc(t.io, relative, self.allocator(), .limited(16 * 1024 * 1024));
    }
    pub fn exists(self: *Harness, relative: []const u8) !bool {
        self.temporary.dir.access(t.io, relative, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
    pub fn absent(self: *Harness, relative: []const u8) !void {
        try t.expect(!try self.exists(relative));
    }
    pub fn invoke(self: *Harness, args: []const []const u8, success: bool) !Result {
        const argv = try self.allocator().alloc([]const u8, args.len + 1);
        argv[0] = self.executable;
        @memcpy(argv[1..], args);
        const result = try self.process(argv);
        const succeeded = result.term == .exited and result.term.exited == 0;
        // Expected diagnostics must be ordinary CLI exits, never a crash that
        // happens to satisfy the nonzero-status half of an error scenario.
        if (result.term != .exited or succeeded != success) {
            std.debug.print("CLI argv: {any}\nterm: {any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ args, result.term, result.stdout, result.stderr });
            return error.UnexpectedCliResult;
        }
        self.checks += 1;
        return result;
    }
    pub fn command(self: *Harness, mode: []const u8, script_path: []const u8, args: []const []const u8, success: bool) !Result {
        const argv = try self.allocator().alloc([]const u8, args.len + 4);
        argv[0] = mode;
        argv[1] = script_path;
        argv[2] = "--libtypst";
        argv[3] = self.library;
        @memcpy(argv[4..], args);
        return self.invoke(argv, success);
    }
    pub fn process(self: *Harness, args: []const []const u8) !Result {
        return std.process.run(self.allocator(), t.io, .{ .argv = args, .cwd = .{ .dir = self.temporary.dir }, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .deadline = .fromNow(t.io, .{ .raw = .fromSeconds(30), .clock = .awake }) } });
    }
    pub fn pdfText(self: *Harness, file: []const u8, layout: bool) ![]const u8 {
        const result = try self.process(&.{ "pdftotext", if (layout) "-layout" else "-raw", try self.path(file), "-" });
        try t.expect(result.term == .exited and result.term.exited == 0);
        return result.stdout;
    }
    pub fn svg(self: *Harness, file: []const u8) !Svg {
        return Svg.parse(self.allocator(), try self.read(file));
    }
};
pub fn contains(text: []const u8, fragment: []const u8) !void {
    if (std.mem.indexOf(u8, text, fragment) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ fragment, text });
        return error.TestExpectedSubstring;
    }
}
pub fn excludes(text: []const u8, fragment: []const u8) !void {
    try t.expect(std.mem.indexOf(u8, text, fragment) == null);
}
pub fn either(text: []const u8, a: []const u8, b: []const u8) !void {
    try t.expect(std.mem.indexOf(u8, text, a) != null or std.mem.indexOf(u8, text, b) != null);
}
pub fn output(result: Result, expected: []const u8) !void {
    try t.expectEqualStrings(expected, result.stdout);
}
pub const Attribute = struct { name: []const u8, value: []const u8 };
pub const Element = struct {
    name: []const u8,
    svg_namespace: bool,
    attributes: []const Attribute,
    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |attribute| if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        return null;
    }
};
pub const Svg = struct {
    elements: []const Element,
    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Svg {
        var source: xml.Reader.Static = .init(a, bytes, .{});
        defer source.deinit();
        const reader = &source.interface;
        var elements: std.ArrayList(Element) = .empty;
        while (true) switch (try reader.read()) {
            .eof => break,
            .element_start => {
                const ns = reader.elementNameNs();
                const attrs = try a.alloc(Attribute, reader.attributeCount());
                for (attrs, 0..) |*attribute, index| attribute.* = .{ .name = try a.dupe(u8, reader.attributeName(index)), .value = try a.dupe(u8, reader.attributeValueRaw(index)) };
                try elements.append(a, .{ .name = try a.dupe(u8, ns.local), .svg_namespace = std.mem.eql(u8, ns.ns, "http://www.w3.org/2000/svg"), .attributes = attrs });
            },
            else => {},
        };
        try t.expect(elements.items.len != 0);
        try t.expectEqualStrings("svg", elements.items[0].name);
        try t.expect(elements.items[0].svg_namespace);
        return .{ .elements = try elements.toOwnedSlice(a) };
    }
    pub fn count(self: Svg, name: []const u8) usize {
        var n: usize = 0;
        for (self.elements) |element| {
            if (element.svg_namespace and std.mem.eql(u8, element.name, name)) n += 1;
        }
        return n;
    }
    pub fn hasAttribute(self: Svg, name: []const u8, value: []const u8) bool {
        for (self.elements) |element| if (element.attr(name)) |actual| {
            if (std.mem.eql(u8, actual, value)) return true;
        };
        return false;
    }
    pub fn viewBox(self: Svg, expected: []const u8) !void {
        try t.expectEqualStrings(expected, self.elements[0].attr("viewBox") orelse return error.MissingViewBox);
    }
};
