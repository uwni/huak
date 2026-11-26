//! Host effects as serial barriers: shared picture mutation, printing and custom host callbacks.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");

test "builders mutating shared pictures and printing remain ordered serial barriers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{draw, picture, append};shared:=picture(100,80)
        \\fn changed(index:int) -> picture
        \\ object.append(shared, object.draw((0,index*1.0)--(90,index*1.0)))
        \\ print(index)
        \\ p:=picture(100,80)
        \\ p.append(copy(shared))
        \\ return p
        \\end
        \\first:=changed(1)
        \\second:=changed(2)
    , true);
    defer program.deinit();
    for ([_]usize{ 1, 4 }) |jobs| {
        var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = &library, .workers = .init(t.io, jobs) }, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
        executor.attach(&machine);
        _ = try machine.execute(&.{});
        try t.expectEqual(@as(usize, 0), executor.stats.tasks);
        try t.expectEqualStrings("1\n2\n", runtime.printedText());
        const first = machine.getGlobal("first").?;
        const second = machine.getGlobal("second").?;
        var first_svg = try runtime.render(first, .svg);
        defer first_svg.deinit();
        var second_svg = try runtime.render(second, .svg);
        defer second_svg.deinit();
        try t.expect(first_svg.bytes().len < second_svg.bytes().len);
    }
}

test "custom host callbacks retain their behavior when construction workers are requested" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{draw, picture};fn figure() -> picture
        \\ p:=picture(100,80)
        \\ object.append(p, object.draw((0,0)--(50,50)))
        \\ return p
        \\end
        \\first:=figure()
        \\second:=figure()
    , true);
    defer program.deinit();
    try t.expect(program.task_regions.len > 0);
    const Callback = std.meta.Child(@FieldType(l.Machine.Host.VTable, "call_builtin"));
    const BuiltinId = @FieldType(std.meta.ArgsTuple(std.meta.Child(Callback)), "2");
    const Wrapped = struct {
        var calls: std.atomic.Value(usize) = .init(0);

        fn call(context: ?*anyopaque, allocator: std.mem.Allocator, id: BuiltinId, arguments: []const l.types.Value, machine: ?*l.Machine) !l.types.Value {
            _ = calls.fetchAdd(1, .monotonic);
            const runtime: *l.Runtime = @ptrCast(@alignCast(context.?));
            const original = runtime.host();
            if (id == .picture) return original.callBuiltin(allocator, id, &.{ .{ .int = 137 }, .{ .int = 83 } }, machine);
            return original.callBuiltin(allocator, id, arguments, machine);
        }
    };
    var expected: ?[]u8 = null;
    defer if (expected) |bytes| t.allocator.free(bytes);
    var expected_calls: ?usize = null;
    for ([_]usize{ 1, 4 }) |jobs| {
        Wrapped.calls.store(0, .monotonic);
        var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = &library, .workers = .init(t.io, jobs) }, .{});
        defer runtime.deinit();
        var host = runtime.host();
        var vtable = host.vtable.*;
        vtable.call_builtin = Wrapped.call;
        host.vtable = &vtable;
        var machine = try l.Machine.init(t.allocator, &program, host, .{});
        defer machine.deinit();
        var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
        executor.attach(&machine);
        _ = try machine.execute(&.{});
        const calls = Wrapped.calls.load(.monotonic);
        if (expected_calls) |count| try t.expectEqual(count, calls) else expected_calls = calls;
        try t.expect(calls > 0);
        try t.expectEqual(@as(usize, 0), executor.stats.tasks);
        var svg = try runtime.render(machine.getGlobal("first").?, .svg);
        defer svg.deinit();
        if (expected) |bytes| try t.expectEqualSlices(u8, bytes, svg.bytes()) else expected = try t.allocator.dupe(u8, svg.bytes());
    }
    const Existing = struct {
        fn task(context: ?*anyopaque, _: *l.Machine, _: *const l.bytecode.TaskRegion) l.Machine.Error!bool {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return false;
        }
    };
    var calls: usize = 0;
    var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = &library, .workers = .init(t.io, 4) }, .{});
    defer runtime.deinit();
    var host = runtime.host();
    host.tasks = .{ .ptr = &calls, .vtable = &.{ .dispatch = Existing.task } };
    var machine = try l.Machine.init(t.allocator, &program, host, .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
    executor.attach(&machine);
    _ = try machine.execute(&.{});
    try t.expect(calls > 0);
    try t.expectEqual(@as(usize, 0), executor.stats.tasks);
}
