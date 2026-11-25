//! Pen motion: units and composition order, normal motion with scale, nib corner choices and Hobby knot directions.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

test "motion expressions retain units and composition order through painted and erased strokes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*; import std.pen_motion.*; import pen.pensquare; import assertions.assert
            \\t := 7
            \\turn := moving() do
            \\    return (scaling x (1 + t * t) y (1 - t / 2)) followed by (rotation by (90deg * t))
            \\end
            \\assert(t + 3 == 10)
            \\nib := pen(rgb(0.2,0.4,0.7), nib:pensquare(4pt), motion:turn, tolerance:0.01pt)
            \\p := (4pt,8pt) -- (24pt,8pt)
            \\export page := drawing picture(30pt,16pt) do
            \\    mask := rectangle((0pt,0pt),30pt,16pt) filled rgb(1,0,0)
            \\    +draw p with nib; +mask
            \\    erase p from [mask] with nib
            \\end
            \\export painted := page.children[0]
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const obj = machine.getGlobal("painted").?.object;
        const owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(obj.owner));
        const motion = (try owner.scene.getNode(obj.index)).path.style.pen.?.motion.?;
        const halfway = motion.at(0.5);
        const expected = huak.core.geometry.Transform.scaling(1.25, 0.75).then(huak.core.geometry.Transform.rotation(std.math.pi / 4.0));
        inline for (.{ "a", "b", "c", "d" }) |field| try t.expectApproxEqAbs(@field(expected, field), @field(halfway, field), 1e-14);
        var svg = try runtime.render(machine.getGlobal("page").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<clipPath") != null);
    }
}

test "standard library normal motion composes with scale in SVG and PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*; import std.pen_motion.*; import pen.pensquare
        \\turn := (scaling x 4 y 1) followed by along_normal()
        \\ink := pen(rgb(0.2,0.4,0.7), nib:pensquare(2pt), motion:turn, tolerance:0.05pt)
        \\p := (10pt,4pt) -- (10pt,20pt)
        \\export page := drawing picture(25pt,25pt) do +draw p with ink end
        \\guide := bezier((5pt,8pt),(18pt,30pt),(32pt,2pt),(45pt,20pt))
        \\export curved := drawing picture(50pt,32pt) do +draw guide with ink end
        \\import object.region
        \\export footprint := region(page.children[0])
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const footprint = try runtime.path(machine.getGlobal("footprint").?);
    const box = footprint.bounds().?;
    try t.expectApproxEqAbs(@as(f64, 8), box.width(), 1e-10);
    try t.expectApproxEqAbs(@as(f64, 18), box.height(), 1e-10);
    var svg = try runtime.render(machine.getGlobal("curved").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    var pdf = try runtime.render(machine.getGlobal("curved").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "normal nib corner choices share one guide but yield distinct painted regions" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*; import pen_motion.*; import pen.pensquare
        \\import object.region; import geometry.region_intersection; import assertions.assert
        \\guide := (2pt,14pt) -- (14pt,14pt) -- (14pt,26pt)
        \\fn brush(mode:string) -> pen
        \\    turn := (scaling x 4 y 0.25) followed by along_normal(corner:mode)
        \\    return pen(rgb(0,0,0),nib:pensquare(2pt),motion:turn,tolerance:0.02pt)
        \\end
        \\pivot := draw(guide,brush("rotate"))
        \\jump := draw(guide,brush("overlap"))
        \\probe := rectangle((16.5pt,11.4pt),0.1pt,0.1pt)
        \\assert(len(region_intersection(region(pivot,0.02pt),probe))>0)
        \\assert(len(region_intersection(region(jump,0.02pt),probe))==0)
        \\import pen.{makepen,stroke_outline}; import geometry.{subpaths,region_difference}
        \\blade := makepen((-1.1pt,0pt) -- (1.1pt,0pt) -- cycle)
        \\seal := stroke_outline(rectangle((2.6pt,2.6pt),94.8pt,94.8pt),pen(rgb(0,0,0),nib:blade,motion:along_normal(corner:"rotate")))
        \\assert(len(subpaths(seal))==2)
        \\assert(len(region_difference(circle((2.2pt,2.2pt),0.1pt),seal))==0)
        \\assert(len(region_intersection(circle((50pt,50pt),1pt),seal))==0)
        \\export page := drawing picture(32pt,32pt) do +pivot; +jump end
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var svg = try runtime.render(machine.getGlobal("page").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    var pdf = try runtime.render(machine.getGlobal("page").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "Hobby knot directions survive picture storage, region extraction and both exports" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*; import pen.pensquare; import pen_motion.*; import object.region; import assertions.assert
        \\knots := [(0pt,0pt),(60pt,80pt),(130pt,20pt),(210pt,90pt)]
        \\motion := (scaling x 3 y 1) followed by along_normal()
        \\brush := pen(rgb(0.2,0.4,0.7),nib:pensquare(2pt),motion:motion,tolerance:0.02pt)
        \\spine := knots[0] ~~ knots[1] ~~ knots[2] ~~ knots[3]
        \\export page := drawing picture(240pt,130pt) do +draw spine with brush; +draw smooth(knots) with brush end
        \\assert(len(region(page.children[0],0.02pt))>0)
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const page = machine.getGlobal("page").?;
    var svg = try runtime.render(page, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    var pdf = try runtime.render(page, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}
