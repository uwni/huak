//! Explicit pictures: bounds, aliases, containment, removal and one container with independent timing.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

test "explicit pictures preserve independent bounds aliases and copied composition" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{rgb, translate, rectangle, bounds, fill, picture, append};import picture.canvas;import assertions.assert
        \\fn stamp(dst: object, at: vec2) -> void
        \\ object.append(dst, object.fill(rectangle(at,4,5), rgb(1,0,0)))
        \\end
        \\first:=picture(80,40); second:=picture(120,70); alias:=first
        \\alias.stamp((2,3))
        \\assert(first.bounds()[0]==(2pt,3pt)); assert(first.bounds()[1]==(6pt,8pt))
        \\second.append(copy(first), translate((20,10)))
        \\first.stamp((40,20))
        \\assert(second.bounds()[0]==(22pt,13pt)); assert(second.bounds()[1]==(26pt,18pt))
        \\assert(first.bounds()[1]==(44pt,25pt))
        \\alias.stamp((60,20)); first.canvas(90,45)
        \\assert(first.bounds()[1]==(64pt,25pt))
    );
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const first = machine.getGlobal("first").?;
    var one = try runtime.render(first, .svg);
    defer one.deinit();
    var two = try runtime.render(machine.getGlobal("second").?, .svg);
    defer two.deinit();
    try t.expect(std.mem.indexOf(u8, one.bytes(), "viewBox=\"0 0 90 45\"") != null);
    try t.expect(std.mem.indexOf(u8, two.bytes(), "viewBox=\"0 0 120 70\"") != null);
    try t.expect(!std.mem.eql(u8, one.bytes(), two.bytes()));
}

test "object targets reject invalid containment and cross-owner reordering" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const failures = [_][]const u8{
        "a:=picture(); b:=picture(); x:=object.append(a, object.fill(geometry.circle((0,0),1))); y:=object.append(b, object.fill(geometry.circle((0,0),1))); object.before(x,y)",
        "import drawing.drawing;a:=picture(); x:=object.append(a, object.fill(geometry.circle((0,0),1))); drawing x do end",
        "picture(0,100)",
    };
    for (failures) |source| {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(machine.failure != null);
    }
}

test "removing an object changes containment without invalidating aliases or descendants" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\parent := picture()
        \\child := object.append(parent, picture())
        \\item := object.append(child, object.fill(geometry.circle((0,0),1)))
        \\alias := item
        \\object.remove(child)
        \\object.show(alias, false)
        \\object.remove(parent)
        \\children := parent.children
        \\detached := child.parent
        \\visible := item.visible
        \\owner := item.parent
    );
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expectEqual(@as(usize, 0), l.types.sequence(machine.getGlobal("children").?).?.len);
    try t.expect(!machine.getGlobal("detached").?.boolean);
    try t.expect(!machine.getGlobal("visible").?.boolean);
    try t.expectEqual(machine.getGlobal("child").?.object, machine.getGlobal("owner").?.object);
    try t.expectEqual(machine.getGlobal("item").?.object, machine.getGlobal("alias").?.object);
}

test "one picture container supports automatic extent nested export copies and independent timing" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*
        \\import assertions.assert
        \\fn make(target:picture)->object
        \\    item := fill(rectangle((0pt,0pt),30pt,15pt))
        \\    drawing target do
        \\        +item
        \\    end
        \\    return item
        \\end
        \\export page := picture()
        \\default page
        \\drawing page do
        \\    child := picture()
        \\    object.transform(child, translate((-20pt,-10pt)))
        \\    +child
        \\    drawing child do
        \\        shape := make(child)
        \\    end
        \\end
        \\child:=page.children[0]; shape:=child.children[0]; assert(page.width==30pt and page.height==15pt)
        \\assert(child.parent==page and child.kind=="picture")
        \\assert(child.width==30pt and child.height==15pt)
        \\fixed := picture(100pt,80pt)
        \\object.clip(fixed,rectangle((-50pt,-50pt),200pt,200pt))
        \\object.append(fixed,copy(child))
        \\copied := copy(fixed)
        \\export inner := copied.children[0]
        \\assert(copied.width==100pt and copied.height==80pt)
        \\assert(copied.children[0].kind=="picture" and copied.children[0]!=child)
        \\export child, fixed, copied
        \\animation.timeline(page,3)
        \\animation.timeline(child,2,false)
        \\animation.animate(shape,"opacity",[[0,0],[1,1]])
    );
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const page = machine.getGlobal("page").?;
    const child = machine.getGlobal("child").?;
    const fixed = machine.getGlobal("fixed").?;
    const copied = machine.getGlobal("copied").?;
    const inner = machine.getGlobal("inner").?;
    try t.expectEqual(copied.object.owner, inner.object.owner);
    try t.expect(copied.object.index != inner.object.index);
    var direct = try runtime.render(child, .svg);
    defer direct.deinit();
    var batch = try runtime.takeOutputs(&.{ page, child, child, fixed, copied, inner });
    defer batch.deinit();
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*buffer| buffer.deinit();
    var whole = try batch.render(t.allocator, 0, .svg, &diagnostic);
    defer whole.deinit();
    var nested = try batch.render(t.allocator, 1, .svg, &diagnostic);
    defer nested.deinit();
    try t.expectEqualSlices(u8, direct.bytes(), nested.bytes());
    try t.expect(std.mem.indexOf(u8, whole.bytes(), "viewBox=\"0 0 30 15\"") != null);
    try t.expect(std.mem.indexOf(u8, whole.bytes(), " 3s ") != null);
    try t.expect(std.mem.indexOf(u8, nested.bytes(), " 2s ") != null);
    try t.expect(std.mem.indexOf(u8, nested.bytes(), " infinite") == null);
    var plain = try batch.render(t.allocator, 3, .svg, &diagnostic);
    defer plain.deinit();
    var duplicate = try batch.render(t.allocator, 4, .svg, &diagnostic);
    defer duplicate.deinit();
    try t.expectEqualSlices(u8, plain.bytes(), duplicate.bytes());
    try t.expect(std.mem.indexOf(u8, plain.bytes(), "viewBox=\"0 0 100 80\"") != null);
    var cropped = try batch.render(t.allocator, 5, .svg, &diagnostic);
    defer cropped.deinit();
    try t.expect(std.mem.indexOf(u8, cropped.bytes(), "viewBox=\"0 0 30 15\"") != null);
}
