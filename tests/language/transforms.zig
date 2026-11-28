//! Mapped callbacks, affine mapping and native bending.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const execute = harness.execute;
const compile = harness.compile;
const compileModules = harness.compileModules;

test "mapped callbacks are reentrant snapshot source pictures and preserve diagnostics and limits" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*;import geometry.point_at;import assertions.assert
        \\import transform.mapped
        \\source:=picture()
        \\object.append(source, draw(path((0pt,0pt),(2pt,0pt)), pen(rgb(0,0,1),1pt)))
        \\fn offset_point(p:vec2,offset:vec2)->vec2 return p+offset end
        \\fn mutate_and_map(p:vec2,original:object)->vec2
        \\    if len(original.paths)==1 then object.append(original, fill(rectangle((20pt,20pt),2pt,2pt))) end
        \\    nested:=mapped(path(p),offset_point,(0pt,3pt))
        \\    return bounds(nested)[0]
        \\end
        \\result:=mapped(source,mutate_and_map,source)
        \\assert(len(source.paths)==2 and len(result.paths)==1)
        \\assert(point_at(result.paths[0],0)==(0pt,3pt))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
    const failures = [_]struct { source: []const u8, message: []const u8, steps: usize = 10000 }{
        .{ .source = "fn broken(p:vec2)->vec2 panic(\"mapping failed\"); return p end; result:=transform.mapped(path((0,0)),broken)", .message = "mapping failed" },
        .{ .source = "fn broken(p:vec2)->vec2 while true do end; return p end; result:=transform.mapped(path((0,0)),broken)", .message = "instruction limit", .steps = 100 },
        .{ .source = "fn wrong(p:vec2)->int return 1 end; result:=transform.mapped(path((0,0)),wrong)", .message = "PointMappingMustReturnVec2" },
        .{ .source = "f:=math.sin; result:=f()", .message = "invalid argument count" },
        .{ .source = "import transform.bent; result:=bent(path((0,0)),path((0,0)))", .message = "InvalidBendGuide" },
        .{ .source = "import transform.bent; result:=bent(path((0,0)),geometry.compound([path((0,0),(1,1)),path((2,2),(3,3))]))", .message = "InvalidBendGuide" },
        .{ .source = "import transform.bent; p:=picture(); object.append(p, object.label(typ[A], (0,0))); result:=bent(p,geometry.bezier((0,0),(1,0),(2,1),(2,2)))", .message = "LabelResolverRequired" },
    };
    for (failures) |failure| {
        var program = try compile(&library, failure.source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{ .instructions = failure.steps });
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const diagnostic = machine.failure.?;
        try t.expect(std.mem.find(u8, diagnostic.text(), failure.message) != null or
            std.mem.find(u8, diagnostic.native_message, failure.message) != null);
    }
}

test "affine mapping and transformation preserve nested clips native text and source objects" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*;import assertions.assert
        \\import transform.{mapped,matrix}
        \\outer:=picture()
        \\object.transform(outer,translate((20pt,30pt)))
        \\clip(outer,rectangle((0pt,0pt),80pt,60pt))
        \\inner:=picture()
        \\object.transform(inner,rotate(15deg))
        \\append(outer,inner)
        \\append(inner,fill(circle((20pt,20pt),12pt),rgb(0.2,0.4,0.8)))
        \\append(inner,label(typ[Affine $x^2$ Ω],(10pt,35pt)))
        \\affine:=matrix(1.2,0.2,-0.3,0.8,7pt,-4pt)
        \\first:=transformed(inner,affine)
        \\second:=mapped(inner,affine)
        \\third:=object.snapshot(inner)
        \\fourth:=transformed(inner,matrix(1,0,0,1,0pt,0pt))
        \\object.remove(inner)
        \\object.transform(inner,translate((100pt,0pt)))
        \\assert(len(outer.children)==0 and len(inner.children)==2)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_]l.Runtime.Format{ .svg, .pdf }) |format| for ([_][2][]const u8{ .{ "first", "second" }, .{ "third", "fourth" } }) |pair| {
            var first = try runtime.render(machine.getGlobal(pair[0]).?, format);
            defer first.deinit();
            var second = try runtime.render(machine.getGlobal(pair[1]).?, format);
            defer second.deinit();
            try t.expectEqualSlices(u8, first.bytes(), second.bytes());
            if (format == .svg) {
                try t.expect(std.mem.find(u8, first.bytes(), "clipPath") != null);
            } else {
                try t.expect(std.mem.find(u8, first.bytes(), "/ToUnicode") != null);
            }
        };
    }
}

test "native bending matches independent analytic parabola and retains straight curves" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import transform.bent
        \\import geometry.{bezier,measure}
        \\import assertions.assert
        \\guide:=bezier((0pt,0pt),(20pt/3,0pt),(40pt/3,20pt/3),(20pt,20pt))
        \\measured:=measure(guide,0.0000125pt)
        \\assert(geometry.sample_at_length(measured,measured.length)[1]==(20pt,20pt))
        \\assert(geometry.samples_at_length(measured,[0pt,measured.length])[1][1]==(20pt,20pt))
        \\result:=bent(path((0pt,2pt),(measured.length,2pt)),guide,0pt,0.0001pt)
        \\bend_function:=transform.bent
        \\straight:=bend_function(guide,path((5pt,7pt),(5pt,27pt)),10pt)
    ;
    var program = try compileModules(&library, source, &.{});
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const result = runtime.path_values.items[machine.getGlobal("result").?.handle.index];
    for (0..result.segmentCount()) |i| {
        const curve = (try result.curveAt(@floatFromInt(i))).curve;
        for ([_]f64{ 0.13, 0.37, 0.61, 0.91 }) |fraction| {
            const point = curve.at(fraction);
            var lo: f64 = 0;
            var hi: f64 = 1;
            for (0..50) |_| {
                const u = (lo + hi) / 2;
                if (20 * u - 4 * u / @sqrt(1 + 4 * u * u) < point.x) lo = u else hi = u;
            }
            const u = (lo + hi) / 2;
            try t.expectApproxEqAbs(20 * u * u + 2 / @sqrt(1 + 4 * u * u), point.y, 2e-4);
        }
    }
    const guide = runtime.path_values.items[machine.getGlobal("guide").?.handle.index];
    var expected = try guide.transformed(t.allocator, .{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 5, .f = 17 });
    defer expected.deinit();
    const straight = runtime.path_values.items[machine.getGlobal("straight").?.handle.index];
    try t.expectEqualDeep(expected.segments.items, straight.segments.items);
}
