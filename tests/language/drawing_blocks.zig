//! Drawing blocks: target snapshots, scope restoration, explicit insertion and dynamic targets.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const scene = @import("../support/scene.zig");
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const execute = harness.execute;

test "drawing snapshots its target and reuses imported prefix functions and native text" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const brushes =
        \\import paint.{rgb, fill};fn paint(curve:path)->object
        \\ print("paint")
        \\ return fill(curve, rgb(0.2,0.4,0.8))
        \\end
        \\mixfix(paint) paint _ in logical_or
        \\export paint
    ;
    const source =
        \\import drawing.drawing
        \\import paint.{circle, draw, fill, label, picture};import "brushes.huak" as brushes
        \\export first:=picture(120,80)
        \\export second:=picture(90,60)
        \\default first
        \\target:=first
        \\curve:=circle((20,20),8)
        \\fn select()->picture;print("target");return target;end
        \\fn marked()->path;print("curve");return curve;end
        \\drawing select() do
        \\ +draw marked()
        \\ +drawing second do
        \\  +fill curve
        \\ end
        \\ target=second
        \\ +draw curve
        \\ +brushes.paint curve
        \\ drawing second do +draw(curve) end
        \\end
        \\object.append(first, draw(curve))
        \\caption:=typ[
        \\Prefix drawing Ω $x^2$
        \\]
        \\object.append(first, object.label(caption, (5,65)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{.{ .name = "/native/brushes.huak", .source = brushes }}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqualStrings("target\ncurve\npaint\n", runtime.printedText());
        try t.expectEqual(@as(usize, 2), scene.canvases(&runtime));
        const first = machine.getGlobal("first").?;
        const second = machine.getGlobal("second").?;
        try t.expectEqual(@as(usize, 6), try scene.childCount(first));
        try t.expectEqual(@as(usize, 2), try scene.childCount(second));
        var second_children = try scene.owner(second).scene.children(second.object.index);
        const filled = second_children.next().?;
        try t.expectEqual(huak.core.DisplayList.Paint.black, (try filled.scene.getNode(filled.index)).path.style.fill.?);
        var first_children = try scene.owner(first).scene.children(first.object.index);
        _ = first_children.next();
        const inserted = first_children.next().?;
        try t.expect(inserted.eql(scene.object(second)));
        _ = first_children.next();
        const painted = first_children.next().?;
        try t.expectApproxEqAbs(@as(f64, 0.8), (try painted.scene.getNode(painted.index)).path.style.fill.?.color.b, 1e-12);
        try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
        var svg = try runtime.render(machine.getGlobal("first").?, .svg);
        defer svg.deinit();
        var pdf = try runtime.render(machine.getGlobal("first").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 120 80\"") != null);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/FontFile") != null);
    }
}

test "drawing scopes restore targets across nested loops and function returns" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import drawing.drawing
        \\import math.sqrt;import paint.{circle, reverse, draw, fill, picture};import assertions.assert
        \\mixfix(reverse) reverse _ in unary
        \\mixfix(sqrt) sqrt _ in unary
        \\assert(sqrt 16==4)
        \\fn same(dst:picture)->picture;return dst;end
        \\mixfix(same) same _ in unary
        \\curve:=circle((10,10),4)
        \\first:=picture(640, 480); second:=picture(640, 480)
        \\fn build(dst:picture,other:picture,p:path)
        \\ drawing dst do
        \\  for i in 1:4 do
        \\   if i==1 then;continue;end
        \\   drawing other do;+fill p;end
        \\   +draw p
        \\   if i==3 then;break;end
        \\  end
        \\ end
        \\end
        \\fn early(dst:picture,p:path)->int
        \\ return drawing dst do
        \\  +fill p
        \\  return 7
        \\ end
        \\end
        \\build(first,second,curve)
        \\assert(early(second,curve)==7)
        \\drawing first do
        \\ assert(same first==first)
        \\ +draw reverse curve
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const first = machine.getGlobal("first").?;
        const second = machine.getGlobal("second").?;
        try t.expectEqual(@as(usize, 3), try scene.childCount(first));
        try t.expectEqual(@as(usize, 3), try scene.childCount(second));
        var strokes = try scene.owner(first).scene.children(first.object.index);
        while (strokes.next()) |node| {
            const item = try node.scene.getNode(node.index);
            if (item.* == .picture) {
                try t.expectEqual(second.object.index, node.index);
            } else try t.expect(item.path.style.pen != null);
        }
        var fills = try scene.owner(second).scene.children(second.object.index);
        while (fills.next()) |node| try t.expect((try node.scene.getNode(node.index)).path.style.fill != null);
    }
}

test "drawing inserts only explicit plus expressions and retains object handles" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*;import assertions.assert
        \\import object.{remove}
        \\fn identity(value:any)->any return value end
        \\expand_block panel(target:picture)
        \\    drawing target do
        \\        ...
        \\    end
        \\    return target
        \\end
        \\fn make()->object
        \\    ignored := fill(circle((80,80),4))
        \\    return draw(path((0,0),(10,10)))
        \\end
        \\export plate := picture(100,100)
        \\default plate
        \\source := fill(circle((20,20),5))
        \\assert(source.parent == false)
        \\drawing plate do
        \\    detached := fill(circle((80,80),4))
        \\    assert(detached.parent==false)
        \\    draw path((0,0),(1,1)) with pen(rgb(0,0,0), 1pt)
        \\    assert(len(plate.children)==0)
        \\    item := source; +item
        \\    identity(item)
        \\    outer := picture(); +outer
        \\    panel outer do
        \\        child := make(); +child
        \\        title := typ[Native text] at (10,25); +title
        \\    end
        \\end
        \\item:=source; outer:=plate.children[1]; child:=outer.children[0]; title:=outer.children[1]; assert(item == source)
        \\assert(plate.children == [item,outer])
        \\assert(outer.children == [child,title])
        \\assert(append(outer,item)==item)
        \\assert(plate.children==[outer])
        \\assert(outer.children==[child,title,item])
        \\remove(item)
        \\assert(item.parent==false)
        \\insertion_result := drawing plate do return +item end
        \\assert(plate.children==[outer,item])
        \\dup:=copy(item)
        \\assert(dup!=item)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expect(machine.getGlobal("insertion_result").? == .unit);
        var svg = try runtime.render(machine.getGlobal("plate").?, .svg);
        defer svg.deinit();
        var pdf = try runtime.render(machine.getGlobal("plate").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<svg") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    }
}

test "drawing validates dynamic and object-typed targets before executing the body" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| for ([_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "import drawing.drawing;drawing [3][0] do end", .message = "expected picture, received int" },
        .{ .source = "import drawing.drawing;drawing [3][0] do panic(\"body ran\") end", .message = "expected picture, received int" },
        .{ .source = "import drawing.drawing;fn enter(target:any);drawing target do panic(\"body ran\") end end;enter(object.fill(path((0,0),(1,1))))", .message = "expected picture, received object" },
    }) |case| {
        var program = try compileModulesOptimized(&library, case.source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expectEqualStrings(case.message, machine.failure.?.text());
    };
}

test "anonymous drawing expressions return targets and unwind unfinished operands" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const input =
        \\import paint.*
        \\calls:=[]
        \\fn make()->picture
        \\    calls+=1
        \\    return drawing picture(80,40) do
        \\        +draw (0,0)--(10,10)
        \\    end
        \\end
        \\default make()
        \\struct Card
        \\    image:picture=drawing picture(10,10) do
        \\        import object.fill as shade
        \\        mixfix(shade) shade _ in unary
        \\        shape := shade ((0,0)--(5,0)--(5,5)--cycle); +shape
        \\    end
        \\end
        \\card:=Card()
        \\other:=drawing picture(40,20) do
        \\    for x in [1,2,3] do
        \\        +draw (x,0)--(x,10)
        \\    end
        \\end
        \\for i in 1:3 do
        \\    discarded:=[99,drawing picture() do
        \\        if i==1 then continue end
        \\        break
        \\    end]
        \\end
        \\answer:=42
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, input, &.{}, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 0), program.exports.len);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(usize, 1), machine.getGlobal("calls").?.list.items().len);
        try t.expectEqual(@as(i64, 42), machine.getGlobal("answer").?.int);
        try t.expectEqual(@as(usize, 3), try scene.childCount(machine.getGlobal("other").?));
        try t.expectEqual(@as(usize, 1), try scene.childCount(machine.getGlobal("card").?.record.fields[0]));
        const default = machine.getGlobalAt(program.outputs[program.outputs.len - 1].global).?;
        try t.expectEqual(@as(usize, 1), try scene.childCount(default));
        var svg = try runtime.render(default, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 80 40\"") != null);
    }
}
