//! Live CLI acceptance: edit actual files while the native watch process runs.
const std = @import("std");
const h = @import("harness.zig");
const t = std.testing;

const Event = struct {
    event: []const u8,
    outputs: []const struct { name: []const u8, path: []const u8 } = &.{},
    duration_ms: ?i64 = null,
    message: ?[]const u8 = null,
};

const Watch = struct {
    context: *h.Harness,
    child: std.process.Child,
    buffer: std.Io.File.MultiReader.Buffer(2),
    reader: std.Io.File.MultiReader,

    fn init(self: *Watch, context: *h.Harness, args: []const []const u8) !void {
        const argv = try context.allocator().alloc([]const u8, args.len + 4);
        argv[0] = context.executable;
        argv[1] = "watch";
        argv[2] = "--libtypst";
        argv[3] = context.library;
        @memcpy(argv[4..], args);
        self.context = context;
        self.child = try std.process.spawn(t.io, .{ .argv = argv, .cwd = .{ .dir = context.temporary.dir }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
        self.reader.init(context.allocator(), t.io, self.buffer.toStreams(), &.{ self.child.stdout.?, self.child.stderr.? });
    }

    fn deinit(self: *Watch) void {
        self.reader.deinit();
        self.child.kill(t.io);
    }

    fn next(self: *Watch) !Event {
        const timeout: std.Io.Timeout = .{ .deadline = .fromNow(t.io, .{ .raw = .fromSeconds(10), .clock = .awake }) };
        while (true) {
            const stream = self.reader.reader(0);
            if (std.mem.indexOfScalar(u8, stream.buffered(), '\n')) |end| {
                const parsed = try std.json.parseFromSlice(Event, self.context.allocator(), stream.buffered()[0..end], .{ .allocate = .alloc_always });
                stream.toss(end + 1);
                return parsed.value;
            }
            self.reader.fill(256, timeout) catch |err| {
                std.debug.print("watch stdout: {s}\nwatch stderr: {s}\n", .{ stream.buffered(), self.reader.reader(1).buffered() });
                return err;
            };
            if (self.reader.reader(1).buffered().len > 1024 * 1024) return error.WatchStderrTooLong;
        }
    }

    fn outcome(self: *Watch, expected: []const u8) !Event {
        const start = try self.next();
        try t.expectEqualStrings("build_start", start.event);
        const result = try self.next();
        if (!std.mem.eql(u8, expected, result.event)) {
            std.debug.print("watch expected {s}, got {s}: {s}\nstderr: {s}\n", .{ expected, result.event, result.message orelse "", self.reader.reader(1).buffered() });
            return error.UnexpectedWatchEvent;
        }
        return result;
    }

    fn finish(self: *Watch, signal: std.posix.SIG) !void {
        try std.posix.kill(self.child.id.?, signal);
        try self.reader.fillRemaining(.{ .deadline = .fromNow(t.io, .{ .raw = .fromSeconds(5), .clock = .awake }) });
        const term = try self.child.wait(t.io);
        try t.expect(term == .exited and term.exited == 0);
    }
};

pub fn run(context: *h.Harness) !void {
    const font = @embedFile("../fixtures/fonts/LibertinusSerif-Regular.otf");
    try context.write("watch-font.otf", font);
    _ = try context.script("watch/dependency", "export width:=10");
    const root_source =
        \\import drawing.drawing
        \\import paint.{draw, picture};import assertions.assert
        \\import "watch/dependency.huak" as config
        \\param size:int=100
        \\print("watch script print")
        \\pic:=picture(size,30)
        \\drawing pic do +draw (0,0)--(config.width,20) end
        \\default pic
        \\export alias:=pic
    ;
    const root = try context.script("watch-root", root_source);
    var process: Watch = undefined;
    try process.init(context, &.{ root, "--json", "--param", "size=120", "--font", "watch-font.otf", "--output", "watch-first.svg", "--output", "alias=watch-second.svg" });
    defer process.deinit();
    const first = try process.outcome("success");
    try t.expectEqual(@as(usize, 2), first.outputs.len);
    try t.expectEqualStrings("default", first.outputs[0].name);
    try t.expectEqualStrings("alias", first.outputs[1].name);
    try t.expectEqualStrings(try context.path("watch-first.svg"), first.outputs[0].path);
    try t.expect(std.fs.path.isAbsolute(first.outputs[1].path));
    try t.expect(first.duration_ms.? >= 0);
    try (try context.svg("watch-first.svg")).viewBox("0 0 120 30");
    try t.expectEqualStrings(try context.read("watch-first.svg"), try context.read("watch-second.svg"));
    const original = try context.read("watch-first.svg");
    const previous_output = try context.temporary.dir.openFile(t.io, "watch-first.svg", .{});
    defer previous_output.close(t.io);

    // A script panic is a failed build, not a host/process exit. Keep the
    // previous successful outputs and recover in this same watch process.
    _ = try context.script("watch-root", root_source ++ "\nassert(false,\"watch assertion failure\")\n");
    try h.contains((try process.outcome("error")).message.?, "watch assertion failure");
    try t.expectEqualStrings(original, try context.read("watch-first.svg"));
    try t.expectEqualStrings(original, try context.read("watch-second.svg"));
    _ = try context.script("watch-root", root_source);
    _ = try process.outcome("success");
    try t.expectEqualStrings(original, try context.read("watch-first.svg"));

    // Module-only edits recompile the source graph and update completed files.
    _ = try context.script("watch/dependency", "export width:=20");
    _ = try process.outcome("success");
    try t.expect(!std.mem.eql(u8, original, try context.read("watch-first.svg")));
    // A preview reading the previous success must never see a later rebuild
    // truncate that inode. Publication replaces the pathname atomically.
    const previous_bytes = try context.allocator().alloc(u8, original.len);
    try t.expectEqual(original.len, try previous_output.readPositionalAll(t.io, previous_bytes, 0));
    try t.expectEqualStrings(original, previous_bytes);
    _ = try context.script("watch/dependency", "export width:=unknown_value");
    const broken = try process.outcome("error");
    try h.contains(broken.message.?, "unknown_value");
    try t.expect(!std.mem.eql(u8, "Reported", broken.message.?));

    // Editor-style atomic replacement and deletion/recreation keep monitoring
    // the pathname rather than a stale file descriptor or inode.
    try context.write("watch/replacement", "export width:=30");
    try context.temporary.dir.rename("watch/replacement", context.temporary.dir, "watch/dependency.huak", t.io);
    _ = try process.outcome("success");
    try context.temporary.dir.deleteFile(t.io, "watch/dependency.huak");
    try h.contains((try process.outcome("error")).message.?, "cannot import");
    _ = try context.script("watch/dependency", "export width:=40");
    _ = try process.outcome("success");

    // A failed import must already be in the dependency set before it exists.
    const with_missing = "import \"watch/new.json\" as added\n" ++ root_source ++ "\nassert(added == 1, \"edited imported data\")";
    _ = try context.script("watch-root", with_missing);
    try h.contains((try process.outcome("error")).message.?, "watch/new.json");
    try context.write("watch/new.json", "1");
    _ = try process.outcome("success");
    try context.write("watch/new.json", "2");
    try h.contains((try process.outcome("error")).message.?, "edited imported data");
    try context.write("watch/new.json", "1");
    _ = try process.outcome("success");

    // Font changes and root removal recover without restarting the process.
    try context.temporary.dir.deleteFile(t.io, "watch-font.otf");
    try h.contains((try process.outcome("error")).message.?, "cannot read font");
    try context.write("watch-font.otf", font);
    _ = try process.outcome("success");
    try context.temporary.dir.deleteFile(t.io, "watch-root.huak");
    try h.contains((try process.outcome("error")).message.?, "cannot read script");
    try context.write("watch-root-replacement", root_source);
    try context.temporary.dir.rename("watch-root-replacement", context.temporary.dir, "watch-root.huak", t.io);
    _ = try process.outcome("success");
    try h.contains(process.reader.reader(1).buffered(), "watch script print");
    try process.finish(.TERM);

    // The initial root can be absent, and Ctrl-C stops a healthy watcher.
    var absent: Watch = undefined;
    try absent.init(context, &.{ "watch-created.huak", "--json", "--output", "watch-created.svg" });
    defer absent.deinit();
    try h.contains((try absent.outcome("error")).message.?, "cannot read script");
    _ = try context.script("watch-created", "import paint.picture;default picture(12,14)");
    _ = try absent.outcome("success");
    try (try context.svg("watch-created.svg")).viewBox("0 0 12 14");
    try absent.finish(.INT);
}
