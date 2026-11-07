//! Targeted investigation of examples/language/brushes.huak. No production
//! instrumentation: compare ordinary execution with optional callback timing.
const std = @import("std");
const builtin = @import("builtin");
const huak = @import("huak");
const typst = @import("libtypst");
const metrics = @import("metrics");
const l = huak.language;
const Value = l.types.Value;
const ms = metrics.milliseconds;
const Digest = [std.crypto.hash.Blake3.digest_length]u8;
const HostCall = @typeInfo(@typeInfo(@FieldType(l.Machine.Host.VTable, "call_builtin")).optional.child).pointer.child;
const BuiltinId = @typeInfo(HostCall).@"fn".param_types[2].?;

const Timing = struct {
    calls: usize = 0,
    nanos: i96 = 0,
    fn finish(self: *Timing, io: std.Io, start: std.Io.Timestamp, count: usize) void {
        self.calls += count;
        self.nanos += start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    }
    fn milliseconds(self: Timing) f64 {
        return @as(f64, @floatFromInt(self.nanos)) / 1_000_000;
    }
};

const Profile = struct {
    io: std.Io,
    base: l.Machine.Host,
    builtins: [std.enums.values(BuiltinId).len]Timing = @splat(.{}),
    text: Timing = .{},
    other: Timing = .{},
    outlines: [64]struct { knots: usize, elapsed: f64 } = undefined,
    outline_count: usize = 0,

    fn context(pointer: ?*anyopaque) *Profile {
        return @ptrCast(@alignCast(pointer.?));
    }
    const host_vtable: l.Machine.Host.VTable = .{ .call_builtin = call, .field = field, .binary = binary, .module = module, .setup_typst = setup, .typst = typeset, .typst_batch = batch, .error_message = message };
    const single_host_vtable = blk: {
        var table = host_vtable;
        table.typst_batch = null;
        break :blk table;
    };

    fn host(self: *Profile) l.Machine.Host {
        return .{ .ptr = self, .vtable = if (self.base.vtable.typst_batch != null) &host_vtable else &single_host_vtable };
    }
    fn call(pointer: ?*anyopaque, a: std.mem.Allocator, id: BuiltinId, args: []const Value, machine: ?*l.Machine) anyerror!Value {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.builtins[@backingInt(id)].finish(self.io, start, 1);
        const result = try self.base.callBuiltin(a, id, args, machine);
        if (id == .profile_outline and self.outline_count < self.outlines.len) {
            self.outlines[self.outline_count] = .{ .knots = l.types.sequence(args[1]).?.len, .elapsed = ms(start, std.Io.Clock.awake.now(self.io)) };
            self.outline_count += 1;
        }
        return result;
    }
    fn field(pointer: ?*anyopaque, a: std.mem.Allocator, value: Value, name: []const u8) anyerror!Value {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.other.finish(self.io, start, 1);
        return self.base.field(a, value, name);
    }
    fn binary(pointer: ?*anyopaque, a: std.mem.Allocator, op: l.bytecode.Op, left: Value, right: Value) anyerror!Value {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.other.finish(self.io, start, 1);
        return self.base.binary(a, op, left, right);
    }
    fn module(pointer: ?*anyopaque, index: u32) anyerror!void {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.other.finish(self.io, start, 1);
        return self.base.selectModule(index);
    }
    fn setup(pointer: ?*anyopaque, source: []const u8) anyerror!void {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.other.finish(self.io, start, 1);
        return self.base.setupTypst(source);
    }
    fn typeset(pointer: ?*anyopaque, a: std.mem.Allocator, request: l.Machine.TypstRequest) anyerror!Value {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.text.finish(self.io, start, 1);
        return self.base.typeset(a, request);
    }
    fn batch(pointer: ?*anyopaque, a: std.mem.Allocator, sources: []const l.Machine.TypstRequest, values: []Value, diagnostic: *l.Machine.TypstBatchDiagnostic) anyerror!void {
        const self = context(pointer);
        const start = std.Io.Clock.awake.now(self.io);
        defer self.text.finish(self.io, start, sources.len);
        return self.base.typesetBatch(a, sources, values, diagnostic);
    }
    fn message(pointer: ?*anyopaque) []const u8 {
        const self = context(pointer);
        return self.base.errorMessage();
    }
    fn report(self: *const Profile, elapsed: f64) void {
        var native_ms: f64 = self.text.milliseconds() + self.other.milliseconds();
        var order: [std.enums.values(BuiltinId).len]usize = undefined;
        for (&order, 0..) |*index, i| {
            index.* = i;
            native_ms += self.builtins[i].milliseconds();
        }
        const Sort = struct {
            fn before(p: *const Profile, left: usize, right: usize) bool {
                return p.builtins[left].nanos > p.builtins[right].nanos;
            }
        };
        std.mem.sort(usize, &order, self, Sort.before);
        std.debug.print("callback_text_ms={d:.3} text_requests={d} callbacks_other_ms={d:.3} execute_outside_callbacks_ms={d:.3}\n", .{ self.text.milliseconds(), self.text.calls, self.other.milliseconds(), elapsed - native_ms });
        for (order[0..@min(order.len, 12)]) |index| {
            const timing = self.builtins[index];
            if (timing.calls == 0) continue;
            std.debug.print("builtin={s} calls={d} total_ms={d:.3}\n", .{ @tagName(@as(BuiltinId, @fromBackingInt(@intCast(index)))), timing.calls, timing.milliseconds() });
        }
        for (self.outlines[0..self.outline_count], 0..) |outline, index|
            std.debug.print("profile_outline_call={d} knots={d} elapsed_ms={d:.3}\n", .{ index, outline.knots, outline.elapsed });
    }
};

const Prepared = struct { batch: l.OutputBatch, executed: std.Io.Timestamp, steps: u64, commands: usize, paths: usize, tasks: usize };
fn prepare(a: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program, profile: ?*Profile) !Prepared {
    var runtime = try l.Runtime.init(a, a, library, .{});
    defer runtime.deinit();
    const host = if (profile) |p| wrapped: {
        if (program.task_regions.len != 0) return error.ProfileWouldChangeTaskScheduling;
        p.base = runtime.host();
        break :wrapped p.host();
    } else runtime.host();
    var machine = try l.Machine.init(a, program, host, .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = a, .io = io, .runtime = &runtime };
    if (profile == null) executor.attach(&machine);
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |failure| std.debug.print("{s}: {s}\n", .{ failure.text(), failure.native_message });
        return err;
    };
    const executed = std.Io.Clock.awake.now(io);
    const target = machine.getGlobal("pic") orelse return error.MissingPicture;
    const batch = try runtime.takeOutputs(&.{target});
    return .{
        .commands = batch.entries[0].?.view.snapshot.picture.commands.items.len,
        .paths = runtime.path_values.items.len,
        .steps = machine.steps,
        .tasks = executor.stats.tasks,
        .batch = batch,
        .executed = executed,
    };
}

fn phases(init: std.process.Init, library_path: []const u8, script: []const u8, output: []const u8, count: usize, instrument: bool) !void {
    const io = init.io;
    const a = std.heap.smp_allocator;
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, script, init.arena.allocator());
    const loading = std.Io.Clock.awake.now(io);
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    const frontend: huak.tooling.Frontend = .{ .allocator = a, .io = io, .source_parser = .init(&library) };
    std.debug.print("mode={s} library={s} profile={any} load_ms={d:.3}\n", .{ @tagName(builtin.mode), library_path, instrument, ms(loading, std.Io.Clock.awake.now(io)) });
    var expected: ?Digest = null;
    for (0..count) |iteration| {
        const start = std.Io.Clock.awake.now(io);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        defer a.free(source);
        const read = std.Io.Clock.awake.now(io);
        var diagnostic: ?l.compiler.Diagnostic = null;
        var program = frontend.compile(source, path, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
            return err;
        };
        const compiled = std.Io.Clock.awake.now(io);
        var profile: Profile = .{ .io = io, .base = .{} };
        var prepared = acquire: {
            defer program.deinit();
            break :acquire try prepare(a, io, &library, &program, if (instrument) &profile else null);
        };
        const detached = std.Io.Clock.awake.now(io);
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        errdefer scratch.deinit();
        errdefer prepared.batch.deinit();
        var native_error: ?typst.Buffer = null;
        errdefer if (native_error) |*detail| detail.deinit();
        var svg = try prepared.batch.render(scratch.allocator(), 0, .svg, &native_error);
        errdefer svg.deinit();
        const rendered = std.Io.Clock.awake.now(io);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = svg.bytes() });
        const written = std.Io.Clock.awake.now(io);
        var digest: Digest = undefined;
        std.crypto.hash.Blake3.hash(svg.bytes(), &digest, .{});
        if (expected) |previous| {
            if (!std.mem.eql(u8, &previous, &digest)) return error.OutputChanged;
        } else expected = digest;
        const length = svg.bytes().len;
        const svg_paths = std.mem.count(u8, svg.bytes(), "<path");
        const validated = std.Io.Clock.awake.now(io);
        svg.deinit();
        if (native_error) |*detail| detail.deinit();
        prepared.batch.deinit();
        scratch.deinit();
        const finished = std.Io.Clock.awake.now(io);
        std.debug.print("iteration={d} read_ms={d:.3} compile_ms={d:.3} execute_ms={d:.3} handoff_ms={d:.3} render_ms={d:.3} write_ms={d:.3} cleanup_ms={d:.3} validation_ms={d:.3} build_ms={d:.3} steps={d} commands={d} native_paths={d} tasks={d} svg_paths={d} bytes={d} hash={s}\n", .{ iteration, ms(start, read), ms(read, compiled), ms(compiled, prepared.executed), ms(prepared.executed, detached), ms(detached, rendered), ms(rendered, written), ms(validated, finished), ms(written, validated), ms(start, written) + ms(validated, finished), prepared.steps, prepared.commands, prepared.paths, prepared.tasks, svg_paths, length, std.fmt.bytesToHex(digest, .lower) });
        if (instrument) profile.report(ms(compiled, prepared.executed));
    }
    std.debug.print("peak_rss_bytes={d}\n", .{metrics.peakRssBytes()});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1) {
        std.debug.print("usage: bench-brushes LIBTYPST SCRIPT OUTPUT REPETITIONS [profile]\n", .{});
        return;
    }
    if (args.len < 5 or args.len > 6) return error.InvalidArguments;
    const count = try std.fmt.parseInt(usize, args[4], 10);
    if (count == 0 or count > 20) return error.InvalidArguments;
    try phases(init, args[1], args[2], args[3], count, args.len == 6 and std.mem.eql(u8, args[5], "profile"));
}
