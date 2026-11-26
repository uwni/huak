//! Allocation failure during worker publication and diagnostic copies.
const scene = @import("../support/scene.zig");
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");

fn allocationScenario(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program) !void {
    // Force allocation fallback for reproducible failure indices. The actual
    // worker path still runs; this backend supplies no additional threads.
    var allocation_only = t.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const stable = allocation_only.allocator();
    var scene_allocator = t.FailingAllocator.init(stable, .{ .resize_fail_index = 0 });
    defer std.debug.assert(scene_allocator.allocated_bytes == scene_allocator.freed_bytes);
    var runtime = try l.Runtime.initWithBackends(stable, scene_allocator.allocator(), .{ .typst = library, .workers = .init(io, 4) }, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(stable, program, runtime.host(), .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = stable, .runtime = &runtime };
    executor.attach(&machine);
    _ = try machine.execute(&.{});
    var batch = try runtime.takeOutputs(&.{ machine.getGlobal("first").?, machine.getGlobal("second").? });
    defer batch.deinit();
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*detail| detail.deinit();
    var svg = try batch.render(stable, 0, .svg, .serial, &diagnostic);
    defer svg.deinit();
    try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
    try t.expect(executor.stats.tasks >= 2);
}

test "worker snapshots publication diagnostics and moved owners survive every allocation failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{draw, label, picture};caption:=typ[Owned worker text Ω]
        \\fn figure(index:int) -> picture
        \\ local:=typ[Worker #huak.index]
        \\ p:=picture(100,80)
        \\ object.append(p, object.draw((0,0)~~(25,index*1.0)~~(75,50)))
        \\ object.append(p, object.label(caption, (5,60)))
        \\ object.append(p, object.label(local, (5,40)))
        \\ return p
        \\end
        \\first:=figure(1)
        \\second:=figure(2)
    , true);
    defer program.deinit();
    try t.expect(program.task_regions.len > 0);
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    // Initialize native shared resources before counting host allocations.
    var warmup = try harness.evaluate(&library, &program, 1, &.{"first"});
    warmup.outputs.deinit();
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{ threaded.io(), &library, &program });
}

fn failureAllocationScenario(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program) !void {
    var allocation_only = t.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const stable = allocation_only.allocator();
    var runtime = try l.Runtime.initWithBackends(stable, stable, .{ .typst = library, .workers = .init(io, 4) }, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(stable, program, runtime.host(), .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = stable, .runtime = &runtime };
    executor.attach(&machine);
    _ = machine.execute(&.{}) catch |err| {
        // A failed diagnostic copy must not publish a handle and then roll
        // its owner back. Check even on OOM, before any further allocation.
        for (machine.globals, machine.initialized) |value, initialized| {
            if (initialized and value == .object) {
                const owner = scene.owner(value);
                try t.expect(owner.owner_index < runtime.scene_values.items.len);
                try t.expectEqual(owner, runtime.scene_values.items[owner.owner_index]);
            }
        }
        if (err == error.OutOfMemory) return err;
        try t.expectEqual(error.RuntimeFailed, err);
        try t.expect(machine.failure != null);
        try t.expect(machine.getGlobal("first") != null);
        try t.expect(machine.getGlobal("second") == null);
        var batch = try runtime.takeOutputs(&.{machine.getGlobal("first").?});
        defer batch.deinit();
        try batch.validate(0, .svg);
        return;
    };
    return error.ExpectedArithmeticFailure;
}

test "diagnostic copy allocation failures never publish rolled-back picture handles" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{draw, picture};fn figure(index:int) -> picture
        \\ p:=picture(100,80)
        \\ y:=10.0/(2-index)
        \\ object.append(p, object.draw((0,0)--(50,y)))
        \\ return p
        \\end
        \\first:=figure(1)
        \\second:=figure(2)
        \\third:=figure(3)
    , true);
    defer program.deinit();
    try t.expect(program.task_regions.len > 0);
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    try t.checkAllAllocationFailures(t.allocator, failureAllocationScenario, .{ threaded.io(), &library, &program });
}
