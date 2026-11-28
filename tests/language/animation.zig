//! Animation targets and per-picture timeline state.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const scene = @import("../support/scene.zig");
const harness = @import("harness.zig");
const execute = harness.execute;
const compile = harness.compile;

test "drawing returns typed instances and appended groups remain animation targets" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var program = try l.compiler.compile(t.allocator,
            \\import paint.*;import animation.{timeline, animate};import assertions.assert
            \\fn mark(dst:object, x:number) -> object
            \\    result := fill(circle((x,20),3))
            \\    drawing dst do
            \\        +result
            \\    end
            \\    return result
            \\end
            \\pic:=picture(100,80)
            \\curve:=circle((20,20),5)
            \\first:object:=object.append(pic, object.draw(curve))
            \\second:=object.append(pic, object.draw(curve))
            \\assert(first!=second)
            \\saved:=[first,second]
            \\group:=picture()
            \\object.append(pic, group)
            \\object.append(group, object.filldraw(curve, rgb(1,0,0), pen(rgb(0,0,0),1)))
            \\text_object:=object.append(group, object.label(typ[Native text], (10,30)))
            \\component:=picture()
            \\child:=mark(component,10)
            \\mark(component,30)
            \\left:=pic.append(copy(component))
            \\right:=pic.append(copy(component), translate((30,0)))
            \\assert(left!=right and left!=child)
            \\empty:=pic.append(copy(picture()))
            \\assert(str(first)=="<object>")
            \\assert(saved[0]==first and saved[1]==second)
            \\pic.timeline(2,false)
            \\animate(saved[0],"opacity",[[0,0],[1,1]])
            \\animate(group,"translate",[[0,(0,0)],[1,(10,0)]])
            \\animate(left,"opacity",[[0,1],[1,0]])
            \\animate(right,"opacity",[[0,0],[1,1]])
            \\animate(empty,"opacity",[[0,0],[1,1]])
        , "object-handles.huak", .{ .optimize = optimize, .source_parser = .init(&library) }, &diagnostic);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const pic = machine.getGlobal("pic").?;
        const owner = scene.owner(pic);
        const left = machine.getGlobal("left").?.object;
        const right = machine.getGlobal("right").?.object;
        const left_owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(left.owner));
        const right_owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(right.owner));
        try t.expect(left_owner != right_owner);
        try t.expect((try left_owner.scene.getNode(left.index)).* == .picture);
        try t.expect(!left_owner.scene.contains(left.index, right_owner.scene.object(right.index)));
        var selected = try owner.view(t.allocator, 0);
        defer selected.deinit();
        try t.expectEqual(@as(usize, 5), selected.tracks.items.len);
        var svg = try runtime.render(pic, .svg);
        defer svg.deinit();
        // Each of the five targets plays its track; equal keys share keyframes.
        try t.expectEqual(@as(usize, 5), std.mem.count(u8, svg.bytes(), " class=\"huak-a"));
        try t.expectEqual(@as(usize, 3), std.mem.count(u8, svg.bytes(), "@keyframes "));
    }
}

test "script animation uses one retained frame and continuous native object tracks" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, circle, fill, label, picture};import animation.{timeline, animate};pic:=picture(200,100); pic.timeline(2.5,false)
        \\t:=typ[
        \\Move Ω
        \\]
        \\id:=object.append(pic, object.label(t, (10,30)))
        \\animate(id,"translate",[[0,(0,0)],[0.37,(50,20)],[1,(100,0)]])
        \\ball:=object.append(pic, object.fill(circle((20,20),5), rgb(0,0,1)))
        \\animate(ball,"fill",[[0,rgb(0,0,1)],[1,rgb(1,0,0)]])
        \\animate(ball,"opacity",[[0,0.2],[1,1]])
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.find(u8, svg.bytes(), "37%{transform:translate(50px,20px)}") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "2.5s linear both") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "100%{fill:rgb(255,0,0)}") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "0%{opacity:0.2}") != null);
    try t.expectError(error.AnimationRequiresSvg, runtime.render(machine.getGlobal("pic").?, .pdf));
    // Encoding the same immutable scene again doesn't evaluate text again.
    var again = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer again.deinit();
    try t.expectEqualSlices(u8, svg.bytes(), again.bytes());
    try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
}

test "animation and group state belong to each explicit picture" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{rgb, pen, translate, rectangle, circle, fill, filldraw, picture, append};import animation.{timeline, animate};animated:=picture(80,40); static:=picture(100,50)
        \\id:=object.append(animated, object.fill(circle((10,10),2), rgb(1,0,0)))
        \\animated.timeline(1.25)
        \\group:=picture()
        \\object.transform(group, translate((10,5)))
        \\object.clip(group, rectangle((0,0),20,20))
        \\object.append(static, group)
        \\object.append(group, object.filldraw(rectangle((1,1),5,5), rgb(0,0,1), pen(rgb(0,0,0),1)))
        \\static.append(copy(animated)); animate(id,"opacity",[[0,0],[1,1]])
    );
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var animated = try runtime.render(machine.getGlobal("animated").?, .svg);
    defer animated.deinit();
    var static = try runtime.render(machine.getGlobal("static").?, .svg);
    defer static.deinit();
    var pdf = try runtime.render(machine.getGlobal("static").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.find(u8, animated.bytes(), "@keyframes ") != null);
    try t.expect(std.mem.find(u8, animated.bytes(), " 1.25s ") != null);
    try t.expect(std.mem.find(u8, static.bytes(), "<style>") == null);
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}
