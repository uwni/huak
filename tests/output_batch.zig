//! Real native output handoff, alias ownership and allocation-failure coverage.
const scene = @import("support/scene.zig");
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const language = huak.language;
const OutputBatch = language.OutputBatch;
const DisplayList = huak.core.DisplayList;
const Path = huak.core.Path;
const Owner = language.Runtime.SceneOwner;
const AnimationState = @FieldType(Owner, "animation_state");

const script =
    \\import paint.{draw, label, picture};setup_typst { set text(size: 14pt) }
    \\unused_text := typ[Unselected text]
    \\unused_width := unused_text.width
    \\shared := typ[Shared native text Ω $x^2$]
    \\private := typ[Second picture]
    \\unused := picture(120,80)
    \\object.append(unused, object.label(unused_text, (5,20)))
    \\first := picture(200,100)
    \\object.append(first, object.draw((5,5)--(180,5)--(180,90)))
    \\object.append(first, object.label(shared, (5,30)))
    \\object.append(first, object.label(shared, (5,65)))
    \\second := picture(200,100)
    \\object.append(second, object.label(shared, (5,30)))
    \\object.append(second, object.label(private, (5,65)))
;

fn sourceBlock(context: *anyopaque, source: []const u8) !usize {
    const library: *typst.Library = @ptrCast(@alignCast(context));
    return library.sourceBlock(source);
}

fn compile(allocator: std.mem.Allocator, library: *typst.Library) !language.bytecode.Program {
    var diagnostic: ?language.compiler.Diagnostic = null;
    return language.compiler.compile(allocator, script, "output-batch.huak", .{
        .source_parser = .{ .ptr = library, .vtable = &.{ .block = sourceBlock } },
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

fn execute(machine: *language.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

/// All compiler, VM and mutable runtime owners are destroyed before returning.
fn detachedBatch(allocator: std.mem.Allocator, library: *typst.Library) !OutputBatch {
    var program = try compile(allocator, library);
    defer program.deinit();
    var runtime = try language.Runtime.init(allocator, allocator, library, .{});
    defer runtime.deinit();
    var machine = try language.Machine.init(allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const first = machine.getGlobal("first").?;
    var batch = try runtime.takeOutputs(&.{ first, first, machine.getGlobal("second").? });
    errdefer batch.deinit();
    try t.expectError(error.InvalidState, runtime.takeOutputs(&.{first}));
    try t.expectError(error.InvalidState, runtime.render(first, .svg));
    return batch;
}

fn render(batch: *const OutputBatch, index: usize, format: huak.render.Format) !huak.render.Output {
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*buffer| buffer.deinit();
    return batch.render(t.allocator, index, format, &diagnostic) catch |err| {
        if (diagnostic) |message| std.debug.print("native: {s}\n", .{message.bytes()});
        return err;
    };
}

test "object storage rolls over before growth and isolates oversized geometry" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var diagnostic: ?language.compiler.Diagnostic = null;
    var program = try language.compiler.compile(t.allocator,
        \\curve := geometry.circle((0,0), 5)
        \\for i in 1:500 do
        \\    item := object.fill(curve)
        \\end
        \\points := []
        \\for i in 1:1600 do
        \\    points += (i,0)
        \\end
        \\large := object.draw(path(points))
        \\small := object.fill(curve)
    , "storage-budget.huak", .{}, &diagnostic);
    defer program.deinit();
    var runtime = try language.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expect(runtime.scene_values.items.len > 2);
    for (runtime.scene_values.items) |owner| {
        // Large individual paths are allowed, but must not retain unrelated
        // objects in the same page. Normal pages keep the existing 64 KiB bound.
        if (owner.scene.allocatedBytes() > 64 * 1024)
            try t.expectEqual(@as(usize, 1), owner.scene.nodes.items.len);
    }
    try t.expect(machine.getGlobal("large").?.object.owner != machine.getGlobal("small").?.object.owner);
}

test "detached outputs retain shared native text after VM runtime and engine destruction" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var batch = try detachedBatch(t.allocator, &library);
    defer batch.deinit();
    try t.expectEqual(@as(usize, 3), batch.len());

    var first = try render(&batch, 0, .svg);
    defer first.deinit();
    try t.expect(std.mem.startsWith(u8, first.bytes(), "<svg"));
    try t.expect(std.mem.indexOf(u8, first.bytes(), "<use ") != null);
    batch.release(0);
    try t.expectError(error.ReleasedOutput, batch.validate(0, .svg));

    var alias = try render(&batch, 1, .svg);
    defer alias.deinit();
    try t.expectEqualSlices(u8, first.bytes(), alias.bytes());
    batch.release(1);

    // The other picture still owns the shared text after both aliases finish.
    var second = try render(&batch, 2, .pdf);
    defer second.deinit();
    try t.expect(std.mem.startsWith(u8, second.bytes(), "%PDF-"));
    try t.expect(std.mem.indexOf(u8, second.bytes(), "/ToUnicode") != null);
    batch.release(2);
}

test "output preparation validates animation before frame references without consuming sources" {
    var library: typst.Library = undefined;
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.beginScope(.{}, null);
    try picture.addLabel(0, .{ .width = 10, .height = 12, .baseline = 9 }, .{});
    try picture.endScope();
    var owner: Owner = .{
        .scene = try huak.core.Scene.fromDisplayList(&picture),
        .animation_state = AnimationState.init(t.allocator),
        .owner_index = 0,
    };
    defer owner.scene.deinit();
    defer owner.animation_state.deinit();
    const types = language.types;
    const keys = [_]types.Value{
        types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }),
        types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }),
    };
    try owner.animation_state.animate(1, "opacity", &keys, "linear", null);
    const settings = try owner.scene.settings(0);
    settings.size = .{ .x = 20, .y = 20 };
    for ([_]struct { duration: ?f64, failure: anyerror }{
        .{ .duration = null, .failure = error.MissingTimeline },
        .{ .duration = 0, .failure = error.InvalidTiming },
        .{ .duration = 2, .failure = error.InvalidFrameReference },
    }) |case| {
        settings.duration = case.duration;
        try t.expectError(case.failure, OutputBatch.init(t.allocator, &library, &.{owner.scene.object(0)}, &.{}));
        try t.expectEqual(@as(usize, 2), owner.scene.nodes.items.len);
        try t.expectEqual(@as(usize, 1), owner.animation_state.tracks.len());
        try t.expectEqual(@as(u32, 0), (try owner.scene.getNode(1)).label.reference);
    }
}

test "frame compaction preserves paint order across map growth and shared layout release" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var requests: [24]typst.LayoutRequest = undefined;
    inline for (&requests, 0..) |*request, i| request.* = .{ .source = std.fmt.comptimePrint("Frame {d}", .{i}) };
    var metrics: [requests.len]typst.Metrics = undefined;
    var layout = result: {
        var engine = try library.createEngine();
        defer engine.deinit();
        break :result try engine.layoutContent(&requests, &metrics, null);
    };
    defer layout.deinit();
    var frames: [requests.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, i| frame.* = try layout.frame(i);
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    // Visit every frame in a different order, including repeated references.
    for (0..2 * requests.len) |i| {
        const index = (i * 5 + 7) % requests.len;
        const metric = metrics[index];
        try picture.labelAtBaseline(@intCast(index), .{ .width = metric.width, .height = metric.height, .baseline = metric.baseline }, .{ .x = 5, .y = @floatFromInt(12 * i + 10) }, .{});
    }
    var owner: Owner = .{
        .scene = try huak.core.Scene.fromDisplayList(&picture),
        .animation_state = AnimationState.init(t.allocator),
        .owner_index = 0,
    };
    defer owner.scene.deinit();
    defer owner.animation_state.deinit();
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*buffer| buffer.deinit();
    var expected = result: {
        var view = try owner.view(t.allocator, 0);
        defer view.deinit();
        const render_scene: huak.render.Scene = .{ .picture = &view.snapshot.picture, .width = 200, .height = 600, .frames = &frames };
        break :result try render_scene.render(t.allocator, &library, .svg, &diagnostic);
    };
    defer expected.deinit();
    (try owner.scene.settings(0)).size = .{ .x = 200, .y = 600 };
    var batch = try OutputBatch.init(t.allocator, &library, &.{ owner.scene.object(0), owner.scene.object(0) }, &frames);
    defer batch.deinit();
    try t.expect(layout.handle == null);
    batch.release(0);
    var actual = try render(&batch, 1, .svg);
    defer actual.deinit();
    try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
}

test "last output alias releases picture geometry before the batch is destroyed" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var tracked: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer _ = tracked.deinit();
    const allocator = tracked.allocator();
    var picture = DisplayList.init(allocator);
    defer picture.deinit();
    try picture.beginScope(.{}, null);
    {
        var path = Path.init(allocator);
        defer path.deinit();
        try path.moveTo(.{ .x = 0, .y = 0 });
        for (0..8192) |index| try path.lineTo(.{ .x = @floatFromInt(index % 200), .y = @floatFromInt(index % 100) });
        try picture.draw(path, .{}, .{});
    }
    try picture.endScope();
    var owner: Owner = .{
        .scene = try huak.core.Scene.fromDisplayList(&picture),
        .animation_state = AnimationState.init(allocator),
        .owner_index = 0,
    };
    defer owner.scene.deinit();
    defer owner.animation_state.deinit();
    (try owner.scene.settings(0)).size = .{ .x = 200, .y = 100 };
    var batch = try OutputBatch.init(allocator, &library, &.{ owner.scene.object(0), owner.scene.object(0) }, &.{});
    var alive = true;
    defer if (alive) batch.deinit();
    const retained = tracked.total_requested_bytes;
    {
        var svg = try render(&batch, 0, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    }
    batch.release(0);
    try t.expectEqual(retained, tracked.total_requested_bytes);
    batch.release(1);
    // Geometry dwarfs the small entries table which intentionally stays alive.
    try t.expect(retained - tracked.total_requested_bytes >= 8192 * @sizeOf(huak.core.Path.Segment));
    batch.deinit();
    alive = false;
    try t.expectEqual(@as(usize, 0), tracked.total_requested_bytes);
}

fn allocationHandoff(allocator: std.mem.Allocator, library: *typst.Library) !void {
    var program = try compile(t.allocator, library);
    defer program.deinit();
    var runtime = try language.Runtime.init(t.allocator, t.allocator, library, .{});
    defer runtime.deinit();
    var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const first_value = machine.getGlobal("first").?;
    const second_value = machine.getGlobal("second").?;
    const first = scene.object(first_value);
    const second = scene.object(second_value);
    try second.scene.place(second.index, try firstChild(first), null);
    const first_count = first.scene.nodes.items.len;
    const second_count = second.scene.nodes.items.len;
    const shared_handle = runtime.frames.items[1].layout.handle;
    const private_handle = runtime.frames.items[2].layout.handle;
    var batch = OutputBatch.init(allocator, library, &.{ first, first, second }, runtime.frames.items) catch |err| {
        try t.expectEqual(error.OutOfMemory, err);
        try t.expectEqual(first_count, first.scene.nodes.items.len);
        try t.expectEqual(second_count, second.scene.nodes.items.len);
        try t.expectEqual(shared_handle, runtime.frames.items[1].layout.handle);
        try t.expectEqual(private_handle, runtime.frames.items[2].layout.handle);
        // Failure must leave the full source graph usable by the native backend.
        var svg = try runtime.render(first_value, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<use ") != null);
        return err;
    };
    defer batch.deinit();
    try t.expectEqual(@as(usize, 0), first.scene.nodes.items.len);
    try t.expectEqual(@as(usize, 0), second.scene.nodes.items.len);
    try t.expect(runtime.frames.items[1].layout.handle == null);
    try t.expect(runtime.frames.items[2].layout.handle == null);
    try t.expect(runtime.frames.items[0].layout.handle != null);
    batch.release(0);
    var svg = try render(&batch, 1, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<use ") != null);
}

test "batch ownership commit remains transactional at every allocation failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    // Arena remaps depend on heap placement. Fix the allocation fallback so
    // each injected failure exercises the same ownership transaction.
    var stable = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(stable.allocator(), allocationHandoff, .{&library});
}

test "destroying an unstarted batch releases all selected pictures and text owners" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var tracked: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer _ = tracked.deinit();
    var batch = try detachedBatch(tracked.allocator(), &library);
    try t.expect(tracked.total_requested_bytes > 0);
    batch.deinit();
    try t.expectEqual(@as(usize, 0), tracked.total_requested_bytes);
}

test "cross-storage outputs retain geometry and native text after their original canvas finishes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var batch = result: {
        var program = try compile(t.allocator, &library);
        defer program.deinit();
        var runtime = try language.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const first = machine.getGlobal("first").?;
        const second = machine.getGlobal("second").?;
        const unused = machine.getGlobal("unused").?;
        const from = scene.object(first);
        const to = scene.object(second);
        const extra = scene.object(unused);
        try to.scene.place(to.index, try firstChild(from), null);
        try to.scene.place(to.index, try firstChild(extra), null);
        break :result try runtime.takeOutputs(&.{ first, second });
    };
    defer batch.deinit();
    var original = try render(&batch, 1, .svg);
    defer original.deinit();
    batch.release(0);
    var after = try render(&batch, 1, .svg);
    defer after.deinit();
    try t.expectEqualSlices(u8, original.bytes(), after.bytes());
    try t.expect(std.mem.indexOf(u8, after.bytes(), "<path") != null);
    var pdf = try render(&batch, 1, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
}

test "output jobs retain foreign animation keys after runtime and original output release" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var batch = result: {
        var program = try compile(t.allocator, &library);
        defer program.deinit();
        var runtime = try language.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const first = machine.getGlobal("first").?;
        const second = machine.getGlobal("second").?;
        const from = scene.object(first);
        const to = scene.object(second);
        const keys: []const language.types.Value = &.{
            language.types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }),
            language.types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }),
        };
        for ([_]huak.core.Scene.Object{ from, to }) |canvas| {
            const item = try firstChild(canvas);
            const owner: *Owner = @fieldParentPtr("scene", item.scene);
            try owner.animation_state.animate(item.index, "opacity", keys, "linear", null);
        }
        (try to.scene.settings(to.index)).duration = 2;
        (try to.scene.settings(to.index)).repeat = false;
        try to.scene.place(to.index, try firstChild(from), null);
        break :result try runtime.takeOutputs(&.{ first, second });
    };
    defer batch.deinit();
    var before = try render(&batch, 1, .svg);
    defer before.deinit();
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, before.bytes(), "attributeName=\"opacity\""));
    batch.release(0);
    var after = try render(&batch, 1, .svg);
    defer after.deinit();
    try t.expectEqualSlices(u8, before.bytes(), after.bytes());
    try t.expectError(error.AnimationRequiresSvg, batch.validate(1, .pdf));
}

fn firstChild(object: huak.core.Scene.Object) !huak.core.Scene.Object {
    var children = try object.scene.children(object.index);
    return children.next() orelse error.MissingObject;
}
