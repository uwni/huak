//! Paints: colors and gradients for fills and strokes, built and checked in the gradient namespace and read back from pens and objects.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

test "one gradient paints a fill and a stroke and reads back from pens and objects" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var program = l.compiler.compile(t.allocator,
            \\import paint.*;import pen.pencircle;import assertions.assert
            \\ramp:=gradient.linear((0pt,0pt),(40pt,0pt),[rgb(1,0,0),rgb(0,0,1)])
            \\glow:=gradient.radial((20pt,20pt),20pt,[rgb(1,1,1),rgb(0,0,0)],[0,1])
            \\shaft:=object.draw((0pt,0pt)--(30pt,0pt),pen(ramp,2pt))
            \\head:=object.fill((30pt,-4pt)--(40pt,0pt)--(30pt,4pt)--cycle,ramp)
            \\ring:=object.draw(geometry.circle((20pt,20pt),10pt),pencircle(3pt,glow))
            \\read:gradient:=pen(ramp,2pt).paint
            \\solid:color:=pen(rgb(0,0.5,0)).paint
            \\assert(solid.g==0.5)
            \\filled:gradient:=head.fill
            \\stroked:gradient:=object.draw((0pt,0pt)--(1pt,0pt),pen(filled)).pen.paint
            \\export plate:=picture(60pt,50pt)
            \\object.append(plate,shaft); object.append(plate,head); object.append(plate,ring)
        , "paints.huak", .{ .source_parser = .init(&library), .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
            return err;
        };
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const styleOf = struct {
            fn of(value: l.types.Value) !*const huak.core.DisplayList.Style {
                const owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(value.object.owner));
                return (try owner.scene.getNode(value.object.index)).path.style;
            }
        }.of;
        // The shaft's stroke and the head's fill share the ramp's line and
        // colors, so the colors meet at the joint.
        const shaft = (try styleOf(machine.getGlobal("shaft").?)).gradientFor(.stroke).?;
        const head = (try styleOf(machine.getGlobal("head").?)).gradientFor(.fill).?;
        try t.expectEqualDeep(shaft.linear, head.linear);
        try t.expectEqual(@as(f64, 40), shaft.linear.end.x);
        const ring = (try styleOf(machine.getGlobal("ring").?)).gradientFor(.stroke).?;
        try t.expectEqual(@as(f64, 40), ring.radial.end.x);
        var svg = try runtime.render(machine.getGlobal("plate").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.count(u8, svg.bytes(), "<linearGradient") >= 2);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<radialGradient") != null);
    }
}

test "gradients are checked where they are built" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const failures = [_]struct { []const u8, []const u8 }{
        .{ "gradient.linear((0,0),(0,0),[color.rgb(1,0,0),color.rgb(0,0,1)])", "InvalidStyle" },
        .{ "gradient.linear((0,0),(1,0),[color.rgb(1,0,0)])", "InvalidStyle" },
        .{ "gradient.linear((0,0),(1,0),[color.rgb(1,0,0),color.rgb(0,0,1)],[0,0.5])", "InvalidStyle" },
        .{ "gradient.radial((0,0),0pt,[color.rgb(1,0,0),color.rgb(0,0,1)])", "InvalidRadius" },
        .{ "gradient.fan((0,0),[(1,0),(0,1)],[0,1,2],[color.rgb(1,0,0),color.rgb(0,0,1)],[0,1],0.01)", "InvalidStyle" },
        .{ "gradient.patches([(0,0)],[0],[color.rgb(1,0,0)],[0],0.01)", "InvalidStyle" },
    };
    for (failures) |failure| {
        var program = try compile(&library, failure[0]);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(std.mem.indexOf(u8, machine.failure.?.text(), failure[1]) != null);
    }
}

test "a paint parameter takes a color or a gradient and names both" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "object.fill(geometry.circle((0,0),1),3)", "expected color | gradient, found int" },
        .{ "pen(geometry.circle((0,0),1))", "expected color | gradient, found path" },
        // A parameter that takes only a color refuses a gradient.
        .{ "object.flatten_transparency(picture(),gradient.linear((0,0),(1,0),[color.rgb(1,1,1),color.rgb(0,0,0)]))", "expected color, found gradient" },
    }) |case| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, case[0], "invalid-paint.huak", .{}, &diagnostic));
        try t.expectEqualStrings(case[1], diagnostic.?.text());
    }
}
