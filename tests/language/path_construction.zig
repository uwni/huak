//! Building paths: path literals, list appends, arcs, profiles and polygons.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const execute = harness.execute;

test "list append assignment preserves aliases snapshots and runtime path construction" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library,
            \\import drawing.drawing
            \\import math.abs;import paint.{path, bounds, draw, picture};import geometry.{point_at, sample_path};import assertions.assert
            \\param count:int=3
            \\points:=[]
            \\for i in 0:count do
            \\    points += (float(i)*5mm,float(i%2)*4mm)
            \\end
            \\curve:=path(points)
            \\assert(len(points)==count+1)
            \\assert(abs(point_at(curve,float(count)).x-float(count)*5mm)<1e-10mm)
            \\fresh:=[]
            \\other:=[]
            \\fresh+=1
            \\assert(len(other)==0)
            \\box:=bounds(curve)
            \\box_alias:=box
            \\box+=(0mm,0mm)
            \\assert(len(box_alias)==3)
            \\samples:=sample_path(curve,3)
            \\sample:=samples[0]
            \\sample+="native list"
            \\assert(len(samples[0])==6)
            \\items:=[1]
            \\alias:=items
            \\before:=[];before+=items
            \\source:=["x",[2,3]]
            \\calls:=[]
            \\fn evaluated(values:list,calls:list)->list
            \\    calls += 1
            \\    return values
            \\end
            \\alias += evaluated(source,calls)
            \\items += items
            \\alias += true
            \\items += [[8,9]]
            \\assert(items==[1,"x",[2,3],1,"x",[2,3],true,[8,9]])
            \\assert(alias==items and before==[1] and len(calls)==1)
            \\assert(source==["x",[2,3]])
            \\nested:=[]
            \\nested += [source]
            \\source += "last"
            \\assert(len(nested)==1 and nested[0]==source)
            \\assert(len(nested[0])==3)
            \\recordings:=[]
            \\fn record(value:int)->picture
            \\    recordings += value
            \\    return picture(640, 480)
            \\end
            \\first:=record(1)
            \\second:=record(2)
            \\assert(recordings==[1,2])
            \\pic:=picture(100mm,40mm)
            \\drawing pic do
            \\    +draw curve
            \\end
        , &.{}, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 0), program.task_regions.len);
        for ([_][]const u8{ "2", "4", "2" }) |count| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            _ = machine.execute(&.{.{ .name = "count", .value = count }}) catch |err| {
                if (machine.failure) |detail| std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
                return err;
            };
            var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
            defer svg.deinit();
            try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
        }
    }
}

test "path literals lower once preserve point evaluation and reach native vector output" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library,
            \\import drawing.drawing
            \\import paint.{rgb, path, smooth, draw, fill, picture, append};import assertions.assert
            \\import paint
            \\a:=(0mm,0mm); b:=(10mm,15mm); c:=(25mm,5mm); d:=(40mm,20mm)
            \\literal:=a~~b~~c~~d
            \\ordinary:=smooth([a,b,c,d])
            \\mixed:=a--b~~c~~d--cycle
            \\mixed_ordinary:=path([a,b,c,d],true,["straight","smooth","smooth","straight"])
            \\order:=[]
            \\fn mark(x:length) -> vec2
            \\    order += x
            \\    return (x,x/2)
            \\end
            \\fn make_path(a:vec2,b:vec2,c:vec2) -> path
            \\    return a~~b~~c
            \\end
            \\evaluated:=mark(0mm)--mark(10mm)~~mark(20mm)
            \\assert(order==[0mm,10mm,20mm])
            \\arithmetic:=a~~b+(1mm,2mm)~~c
            \\arithmetic_ordinary:=smooth([a,b+(1mm,2mm),c])
            \\closed:=a~~b~~c~~cycle
            \\closed_ordinary:=smooth([a,b,c],true)
            \\export pic:=picture(100mm,80mm)
            \\drawing pic do
            \\    +draw (0mm,0mm)--(10mm,0mm)
            \\    +fill (50mm,10mm)--(60mm,10mm)--(60mm,20mm)--cycle
            \\    +a~~b~~c~~d paint.tapered 1mm paint.filled rgb(0.1,0.3,0.6)
            \\    +typ[Native paths Ω] paint.at (10mm,60mm)
            \\end
        , &.{}, optimize);
        defer program.deinit();
        for (program.functions) |function| if (std.mem.eql(u8, function.name, "make_path")) {
            var constructions: usize = 0;
            for (function.code) |instruction| if (instruction.op == .call_builtin) {
                constructions += 1;
            };
            try t.expectEqual(@as(usize, 1), constructions);
        };
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][2][]const u8{ .{ "literal", "ordinary" }, .{ "mixed", "mixed_ordinary" }, .{ "arithmetic", "arithmetic_ordinary" }, .{ "closed", "closed_ordinary" } }) |names| {
            const actual = runtime.path_values.items[machine.getGlobal(names[0]).?.handle.index];
            const expected = runtime.path_values.items[machine.getGlobal(names[1]).?.handle.index];
            try t.expectEqualDeep(expected.segments.items, actual.segments.items);
        }
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.find(u8, pdf.bytes(), "/ToUnicode") != null);
    }
}

test "invalid path literal endpoints and closing markers remain diagnosed" {
    for ([_]bool{ false, true }) |optimize| {
        for ([_][]const u8{
            "p:=cycle",
            "p:=(0,0)~~cycle",
            "p:=(0,0)--(1,1)--cycle--(2,2)",
            "p:=cycle--(0,0)",
            "p:=1~~2",
            "p:=(0,0)--\n",
            "p:=(0,0)~~;(1,1)",
            "p:=(0,0)..(1,1)",
        }) |source| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, source, "invalid-path.huak", .{ .optimize = optimize }, &diagnostic));
            try t.expect(diagnostic != null);
        }
    }
}

test "arc and profile builtins preserve physical units and runtime validation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library,
            \\import math.{abs, norm};import paint.{path, bezier, bounds};import geometry.{arclength, sample_path};import pen.profile_outline;import assertions.assert
            \\curve:=bezier((0mm,0mm),(0mm,0mm),(0mm,0mm),(100mm,0mm))
            \\assert(abs(arclength(curve)-100mm)<0.001mm)
            \\samples:=sample_path(curve,3)
            \\assert(len(samples)==3)
            \\assert(abs(samples[1][1].x-50mm)<0.001mm)
            \\assert(abs(norm(samples[1][2])-1)<1e-9)
            \\assert(samples[1][0]==0.5 and samples[1][4]==0)
            \\outline:=profile_outline(path((0mm,0mm),(20mm,0mm)),[0,0.5,1],[1mm,4mm,1mm])
            \\box:=bounds(outline); assert(abs(box[1].y-2mm)<0.001mm)
        , &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][]const u8{
            "sample_path(p,1)",
            "sample_path(p,9223372036854775807)",
            "arclength(p,0pt)",
            "profile_outline(p,[0,1],[1mm])",
            "profile_outline(p,[0,0,1],[1mm,2mm,1mm])",
            "profile_outline(p,[0,1],[1mm,-1mm])",
            "profile_outline(p,[0,1],[1deg,1deg])",
        }) |expression| {
            const source = try t.allocator.print("import math.{{abs, norm}};import paint.{{path, bezier, bounds}};import geometry.{{arclength, sample_path}};import pen.profile_outline;p:=path((0,0),(10,0)); result:={s}", .{expression});
            defer t.allocator.free(source);
            var invalid_program = try compileModulesOptimized(&library, source, &.{}, optimize);
            defer invalid_program.deinit();
            var invalid_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer invalid_runtime.deinit();
            var invalid_machine = try l.Machine.init(t.allocator, &invalid_program, invalid_runtime.host(), .{});
            defer invalid_machine.deinit();
            try t.expectError(error.RuntimeFailed, invalid_machine.execute(&.{}));
            try t.expect(invalid_machine.failure != null);
        }
    }
}

test "polygon builtins preserve units modules host calls and native vector exports" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, @embedFile("../fixtures/cli/polygon/drawing.huak"), &.{.{
            .name = "/native/lib/regions.huak",
            .source = @embedFile("../fixtures/cli/polygon/lib/regions.huak"),
        }}, optimize);
        defer program.deinit();
        for ([_][]const u8{ "region_union", "region_intersection", "region_difference", "region_xor", "offset", "stroke_path", "clip_region", "clip_lines" }) |name| {
            var found = false;
            for (program.functions) |function| {
                for (function.code) |instruction| {
                    if (instruction.op == .call_builtin and std.mem.find(u8, program.modules[function.module].source_text[instruction.span.start..instruction.span.end], name) != null) found = true;
                }
            }
            try t.expect(found);
        }
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const clipped_curve = runtime.path_values.items[machine.getGlobal("clipped_curve").?.handle.index];
        const exact = runtime.path_values.items[machine.getGlobal("exact").?.handle.index];
        var clipped_has_cubic = false;
        for (clipped_curve.segments.items) |segment| if (segment == .cubic) {
            clipped_has_cubic = true;
        };
        try t.expect(clipped_has_cubic);
        var exact_curve = false;
        for (exact.segments.items) |segment| if (segment == .cubic) {
            exact_curve = true;
        };
        try t.expect(exact_curve);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try t.expect(std.mem.find(u8, pdf.bytes(), "/ToUnicode") != null);
    }
}

test "polygon argument and topology errors stay checked with bytecode optimization" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        for ([_]struct { expression: []const u8, message: []const u8 }{
            .{ .expression = "region_union(path((0,0),(1mm,0)),a)", .message = "OpenPath" },
            .{ .expression = "offset(a,1mm,\"unknown\")", .message = "InvalidJoin" },
            .{ .expression = "stroke_path(a,1mm,\"unknown\")", .message = "InvalidCap" },
            .{ .expression = "region_xor(a,a,0.001mm,\"unknown\")", .message = "InvalidFillRule" },
            .{ .expression = "clip_region(a,(1deg,1deg),(2deg,2deg))", .message = "DimensionMismatch" },
        }) |case| {
            const source = try t.allocator.print("import paint.{{rectangle, path}};import geometry.{{region_union, region_xor, offset, clip_region}};import pen.stroke_path;a:=rectangle((0,0),10mm,10mm)\nresult:={s}\n", .{case.expression});
            defer t.allocator.free(source);
            var program = try compileModulesOptimized(&library, source, &.{}, optimize);
            defer program.deinit();
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try t.expect(std.mem.find(u8, machine.failure.?.text(), case.message) != null);
            try t.expect(machine.getGlobal("result") == null);
        }
    }
}
