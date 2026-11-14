//! Real source -> bytecode -> VM -> geometry/native typography integration.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const scene = @import("support/scene.zig");
fn compile(library: *typst.Library, source: []const u8) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "native-test.huak", .{ .source_parser = .init(library) }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}
fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

test "function values pass return and import without captured environments" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const modules = [_]ModuleSource{.{ .name = "/native/functions.huak", .source =
        \\export fn add(x:int, y:int=2)->int return x+y end
        \\export alias:=add
    }};
    const source =
        \\import assertions.assert
        \\import "functions.huak" as functions
        \\import "functions.huak".alias as plus
        \\fn apply(f:function,x:int)->int return f(x) end
        \\fn choose()->function return functions.add end
        \\f:=choose()
        \\assert(apply(f,40)==42 and functions.alias(40)==42 and plus(40)==42)
        \\assert(f==functions.add and f!=math.sin)
        \\sine:=math.sin
        \\assert(sine(0deg)==0)
        \\make_path:=path
        \\assert(len(make_path((0,0),(1,1),(2,0)))==2)
        \\value:=7
        \\fn global_value()->int return value end
        \\read:=global_value
        \\value=9
        \\assert(read()==9)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &modules, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
    var diagnostic: ?l.compiler.Diagnostic = null;
    try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, "fn outer(x:int)->function fn inner()->int return x end return inner end", "no-closures.huak", .{}, &diagnostic));
}

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
        try t.expect(std.mem.indexOf(u8, diagnostic.text(), failure.message) != null or
            std.mem.indexOf(u8, diagnostic.native_message, failure.message) != null);
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
                try t.expect(std.mem.indexOf(u8, first.bytes(), "clipPath") != null);
            } else {
                try t.expect(std.mem.indexOf(u8, first.bytes(), "/ToUnicode") != null);
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

test "subpaths preserve contour chains through namespaces UFCS lists and native color rendering" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*;import geometry.{compound, subpaths, region_difference};import object.region;import assertions.assert
        \\import geometry as geo
        \\import geometry.subpaths as split
        \\open:=bezier((0pt,0pt),(0pt,8pt),(12pt,8pt),(12pt,0pt))
        \\outer:=rectangle((20pt,0pt),12pt,12pt)
        \\hole:=reverse(rectangle((23pt,3pt),6pt,6pt))
        \\stationary:=path((50pt,7pt))
        \\multi:=compound([open,outer,hole,stationary])
        \\parts:=geo.subpaths(curve:multi)
        \\assert(len(parts)==4)
        \\assert(len(parts[0])==1 and len(parts[1])==4 and len(parts[2])==4 and len(parts[3])==0)
        \\assert(bounds(parts[0])==bounds(open) and bounds(parts[1])==bounds(outer))
        \\assert(bounds(parts[2])==bounds(hole) and bounds(parts[3])==bounds(stationary))
        \\assert(len(multi.split())==4 and len(subpaths(multi))==4)
        \\assert(len(geo.subpaths(compound([])))==0)
        \\rejoined:=compound(parts)
        \\parts[0]=transformed(parts[0],translate((100pt,0pt)))
        \\parts+=outer
        \\assert(len(parts)==5 and bounds(parts[0])[0].x==100pt)
        \\assert(bounds(open)[0].x==0pt and bounds(rejoined)==bounds(multi))
        \\letter_style:=typ.module[#let style(body) = {set text(font:"Libertinus Serif",size:30pt); body}]
        \\typ.show letter_style.style
        \\letter:=region(typ[O])
        \\loops:=letter.split()
        \\assert(len(loops)==2)
        \\plate:=rectangle((0pt,0pt),30pt,20pt)
        \\cuts:=compound([rectangle((8pt,-1pt),2pt,22pt),rectangle((20pt,-1pt),2pt,22pt)])
        \\regions:=subpaths(region_difference(plate,cuts))
        \\assert(len(regions)==3)
        \\colors:=[rgb(1,0,0),rgb(0,1,0),rgb(0,0,1)]
        \\pic:=picture(30pt,20pt)
        \\for i in 0:len(regions)-1 do object.append(pic, fill(regions[i], colors[i])) end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const original = runtime.path_values.items[machine.getGlobal("multi").?.handle.index];
        const rejoined = runtime.path_values.items[machine.getGlobal("rejoined").?.handle.index];
        try t.expectEqualDeep(original.segments.items, rejoined.segments.items);
        const loops = machine.getGlobal("loops").?.list.items();
        const outside = runtime.path_values.items[loops[0].handle.index];
        const inside = runtime.path_values.items[loops[1].handle.index];
        try t.expect(outside.signedArea() * inside.signedArea() < 0);
        try t.expect(!outside.open and !inside.open);
        const letter = runtime.path_values.items[machine.getGlobal("letter").?.handle.index];
        try t.expect(outside.segments.items.ptr != letter.segments.items.ptr);
        try t.expect(inside.segments.items.ptr != outside.segments.items.ptr);
        const pic = machine.getGlobal("pic").?;
        try t.expectEqual(@as(usize, 3), try scene.childCount(pic));
        var svg = try runtime.render(pic, .svg);
        defer svg.deinit();
        for ([_][]const u8{ "<svg", "#ff0000", "#00ff00", "#0000ff" }) |marker|
            try t.expect(std.mem.indexOf(u8, svg.bytes(), marker) != null);
        var pdf = try runtime.render(pic, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    }
    for ([_][]const u8{ "geometry.subpaths(1)", "geometry.subpaths()", "geometry.subpaths(path((0,0)),path((1,1)))" }) |invalid| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, invalid, "invalid-subpaths.huak", .{}, &diagnostic));
        try t.expect(diagnostic != null);
    }
}

test "formatting preserves prefix binding and native SVG PDF output" {
    const source =
        \\import paint.*
        \\theme:=typ.module[#let style(body) = {set text(size: 11pt); body}]
        \\typ.show theme.style
        \\fn twice(value:int)->int return 2*value end
        \\mixfix(twice) twice _ in addition
        \\prefixed:=twice (2)+3
        \\ordinary:=twice(2)+3
        \\literal:="x=1,y=2"
        \\points:=[
        \\(0mm,0mm),
        \\(10mm,20mm)
        \\]
        \\pic:=picture(40mm,30mm)
        \\drawing pic do
        \\+draw path(points)
        \\+typ[Formatting a=b,c] at (2mm,3mm)
        \\end
    ;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const frontend: huak.tooling.Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&library) };
    var diagnostic: ?l.compiler.Diagnostic = null;
    const formatted = try huak.tooling.format.format(&frontend, source, "format-preservation.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expect(std.mem.indexOf(u8, formatted, "prefixed := twice (2)+3") != null);
    try t.expect(std.mem.indexOf(u8, formatted, "ordinary := twice(2)+3") != null);
    try t.expect(std.mem.indexOf(u8, formatted, "literal := \"x=1,y=2\"") != null);
    try t.expect(std.mem.indexOf(u8, formatted, "typ[Formatting a=b,c]") != null);
    var original_svg: ?[]u8 = null;
    defer if (original_svg) |bytes| t.allocator.free(bytes);
    var original_pdf: ?[]u8 = null;
    defer if (original_pdf) |bytes| t.allocator.free(bytes);
    for ([_][]const u8{ source, formatted }) |input| {
        var program = try compile(&library, input);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(i64, 10), machine.getGlobal("prefixed").?.int);
        try t.expectEqual(@as(i64, 7), machine.getGlobal("ordinary").?.int);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        if (original_svg) |bytes| {
            try t.expectEqualStrings(bytes, svg.bytes());
            try t.expectEqualSlices(u8, original_pdf.?, pdf.bytes());
        } else {
            original_svg = try t.allocator.dupe(u8, svg.bytes());
            original_pdf = try t.allocator.dupe(u8, pdf.bytes());
            const text = try @import("support/pdf.zig").text(pdf.bytes(), .{});
            defer t.allocator.free(text);
            try t.expect(std.mem.indexOf(u8, text, "Formatting a=b,c") != null);
        }
    }
}

test "constant propagation preserves joins loop exits scalar coercion and runtime parameters" {
    const source =
        \\param choose:bool=false
        \\fn same(flag:bool)->int
        \\    value:=0; if flag then value=2 else value=2 end
        \\    return value*3
        \\end
        \\fn different(flag:bool)->int
        \\    value:=0; if flag then value=2 else value=3 end
        \\    return value*3
        \\end
        \\A:=2*3; B:=A+4
        \\folded:=0; if B>8 then folded=1 else panic("unreachable constant branch") end
        \\joined:=same(choose); diverged:=different(choose)
        \\rounded:float:=9007199254740993
        \\rounded_equal:=rounded==9007199254740993
        \\SIGN:=0.0; if choose then SIGN=-0.0 else SIGN=0.0 end
        \\sign:=SIGN
        \\LIMIT:=3*4; FACTOR:=2+3; total:=0
        \\for i in 0:LIMIT do
        \\    if i==2 then continue end
        \\    if i>8 then break end
        \\    total=total+FACTOR
        \\end
        \\j:=0
        \\while j<3 do total=total+1; j=j+1 end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var program = try l.compiler.compile(t.allocator, source, "constant-flow.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        if (optimize) {
            for (program.constants) |constant| if (constant == .string)
                try t.expect(!std.mem.eql(u8, constant.string, "unreachable constant branch"));
            for (program.functions) |function| {
                var products: usize = 0;
                for (function.code) |instruction| if (instruction.op == .multiply) {
                    products += 1;
                };
                if (std.mem.eql(u8, function.name, "same")) try t.expectEqual(@as(usize, 0), products);
                if (std.mem.eql(u8, function.name, "different")) try t.expectEqual(@as(usize, 1), products);
            }
        }
        for ([_]bool{ false, true }) |choose| {
            var machine = try l.Machine.init(t.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "choose", .value = if (choose) "true" else "false" }});
            try t.expectEqual(@as(i64, 1), machine.getGlobal("folded").?.int);
            try t.expectEqual(@as(i64, 6), machine.getGlobal("joined").?.int);
            try t.expectEqual(@as(i64, if (choose) 6 else 9), machine.getGlobal("diverged").?.int);
            try t.expect(!machine.getGlobal("rounded_equal").?.boolean);
            try t.expectEqual(@as(u64, if (choose) 0x8000000000000000 else 0), @as(u64, @bitCast(machine.getGlobal("sign").?.number)));
            try t.expectEqual(@as(i64, 43), machine.getGlobal("total").?.int);
            try t.expectEqual(@as(i64, 3), machine.getGlobal("j").?.int);
        }
    }
}

test "constant propagation retains uninitialized and arithmetic diagnostics" {
    const sources = [_][]const u8{
        "param choose:bool=false\nif not choose then print(MAYBE) end\nMAYBE:=7\nresult:=MAYBE",
        "A:=9223372036854775807\nresult:=A+1",
        "A:=10\nresult:=A/0",
    };
    for (sources) |source| {
        var expected: ?l.compiler.Diagnostic = null;
        for ([_]bool{ false, true }) |optimize| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            var program = try l.compiler.compile(t.allocator, source, "constant-errors.huak", .{ .optimize = optimize }, &diagnostic);
            defer program.deinit();
            var machine = try l.Machine.init(t.allocator, &program, .{}, .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            const failure = machine.failure.?.diagnostic;
            try t.expect(machine.getGlobal("result") == null);
            if (expected) |original| {
                try t.expectEqualStrings(original.text(), failure.text());
                try t.expectEqualDeep(original.span, failure.span);
            } else expected = failure;
        }
    }
}

test "constant propagation respects host effects through direct calls user functions and imports" {
    const BuiltinId = @FieldType(@FieldType(l.bytecode.Export, "target"), "builtin");
    const Mutation = struct {
        machine: ?*l.Machine = null,
        calls: usize = 0,

        fn call(context: ?*anyopaque, _: std.mem.Allocator, id: BuiltinId, args: []const l.types.Value, _: ?*l.Machine) !l.types.Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print or args.len != 1 or args[0] != .string) return error.UnexpectedHostCall;
            self.calls += 1;
            const machine = self.machine.?;
            for (machine.program.global_names, machine.globals) |name, *value| {
                if (std.mem.eql(u8, name, "x")) value.* = .{ .int = 10 };
            }
            return .unit;
        }
    };
    for ([_][]const u8{
        "x:=1\nprint(\"mutate\")\nresult:=x+1",
        "fn touch() print(\"mutate\") end\nx:=1\ntouch()\nresult:=x+1",
        "x:=1\nimport \"mutator.huak\"\nresult:=x+1",
    }) |source| for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var resolver: ModuleResolver = .{ .sources = &.{.{ .name = "/native/mutator.huak", .source = "print(\"mutate\")" }} };
        var program = try l.compiler.compile(t.allocator, source, "/native/main.huak", .{ .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } }, .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var mutation: Mutation = .{};
        var machine = try l.Machine.init(t.allocator, &program, .{ .ptr = &mutation, .vtable = &.{ .call_builtin = Mutation.call } }, .{});
        defer machine.deinit();
        mutation.machine = &machine;
        _ = try machine.execute(&.{});
        try t.expectEqual(@as(usize, 1), mutation.calls);
        try t.expectEqual(@as(i64, 11), machine.getGlobal("result").?.int);
    };
}

test "constant propagation produces the same native SVG PDF and mutable path inputs" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, pen, path, draw, label, picture};param variant:bool=false
        \\FACTOR:=2*3; EDGE:=FACTOR+4
        \\LEFT:=0; if EDGE>8 then LEFT=EDGE else LEFT=-1000 end
        \\TOP:=0; if variant then TOP=20 else TOP=30 end
        \\points:=[(LEFT*1mm,5mm),(30mm,TOP*1mm),(50mm,5mm)]
        \\alias:=points
        \\fn add_point(items:list) items+=(70mm,25mm) end
        \\add_point(alias)
        \\pic:=picture(100mm,70mm)
        \\object.append(pic, object.draw(path(points), pen(rgb(0.15,0.3,0.7),0.5mm)))
        \\caption:=typ[Propagation Ω]
        \\object.append(pic, object.label(caption, (5mm,55mm)))
    ;
    var expected_svg: [2]?[]u8 = .{ null, null };
    var expected_pdf: [2]?[]u8 = .{ null, null };
    defer for (expected_svg) |bytes| if (bytes) |value| t.allocator.free(value);
    defer for (expected_pdf) |bytes| if (bytes) |value| t.allocator.free(value);
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        if (optimize) {
            var conditions: usize = 0;
            for (program.functions[program.entry].code) |instruction| if (instruction.op == .jump_if_false) {
                conditions += 1;
            };
            try t.expectEqual(@as(usize, 1), conditions);
        }
        for ([_]bool{ false, true }, 0..) |variant, index| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "variant", .value = if (variant) "true" else "false" }});
            try t.expectEqual(@as(usize, 4), l.types.sequence(machine.getGlobal("points").?).?.len);
            var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
            defer svg.deinit();
            var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
            try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
            if (expected_svg[index]) |bytes| {
                try t.expectEqualSlices(u8, bytes, svg.bytes());
                try t.expectEqualSlices(u8, expected_pdf[index].?, pdf.bytes());
            } else {
                expected_svg[index] = try t.allocator.dupe(u8, svg.bytes());
                expected_pdf[index] = try t.allocator.dupe(u8, pdf.bytes());
            }
            const text = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            try t.expect(std.mem.indexOf(u8, text, "Propagation Ω") != null);
        }
    }
}

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
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
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
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
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
            const source = try std.fmt.allocPrint(t.allocator, "import math.{{abs, norm}};import paint.{{path, bezier, bounds}};import geometry.{{arclength, sample_path}};import pen.profile_outline;p:=path((0,0),(10,0)); result:={s}", .{expression});
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
        var program = try compileModulesOptimized(&library, @embedFile("fixtures/cli/polygon/drawing.huak"), &.{.{
            .name = "/native/lib/regions.huak",
            .source = @embedFile("fixtures/cli/polygon/lib/regions.huak"),
        }}, optimize);
        defer program.deinit();
        for ([_][]const u8{ "region_union", "region_intersection", "region_difference", "region_xor", "offset", "stroke_path", "clip_region", "clip_lines" }) |name| {
            var found = false;
            for (program.functions) |function| {
                for (function.code) |instruction| {
                    if (instruction.op == .call_builtin and std.mem.indexOf(u8, program.modules[function.module].source_text[instruction.span.start..instruction.span.end], name) != null) found = true;
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
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
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
            const source = try std.fmt.allocPrint(t.allocator, "import paint.{{rectangle, path}};import geometry.{{region_union, region_xor, offset, clip_region}};import pen.stroke_path;a:=rectangle((0,0),10mm,10mm)\nresult:={s}\n", .{case.expression});
            defer t.allocator.free(source);
            var program = try compileModulesOptimized(&library, source, &.{}, optimize);
            defer program.deinit();
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try t.expect(std.mem.indexOf(u8, machine.failure.?.text(), case.message) != null);
            try t.expect(machine.getGlobal("result") == null);
        }
    }
}

test "bytecode calls existing Hobby and linear solver and exports a true native scene" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.abs;import solver.{unknown, equation, solve, value};import paint.{rgb, pen, translate, smooth, reverse, transformed, bounds, draw, picture};import geometry.trimmed;import assertions.assert
        \\pic:=picture(200,100)
        \\s:=solver(); x:=unknown(s); y:=unknown(s)
        \\equation(s,2*x+y,8); equation(s,x-y,1)
        \\result:=solve(s)
        \\assert(result.status=="unique"); assert(result.rank==2)
        \\assert(abs(value(result,x)-3)<0.000001)
        \\assert(abs(value(result,y)-2)<0.000001)
        \\tiny:=(1e-320*x)/1e-320; positive:=+x
        \\assert(positive==x)
        \\equation(s,tiny,3)
        \\p:=smooth([(10,10),(50,70),(100,20)])
        \\q:=transformed(reverse(p),translate((20,0)))
        \\object.append(pic, object.draw(p)); object.append(pic, draw(q, pen(rgb(0,0.2,0.8),2)))
        \\box:=bounds(p); assert(box[0].x<=10pt)
        \\assert(len(trimmed(p,0,1))==1)
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const knots = [_]huak.core.hobby.Knot{ .{ .point = .{ .x = 10, .y = 10 } }, .{ .point = .{ .x = 50, .y = 70 } }, .{ .point = .{ .x = 100, .y = 20 } } };
    const reference = try huak.core.hobby.interpolate(t.allocator, &knots, .{});
    defer t.allocator.free(reference);
    const first = runtime.path_values.items[machine.getGlobal("p").?.handle.index].segments.items[1].cubic;
    try t.expectApproxEqAbs(reference[0].p1.x, first.c1.x, 1e-12);
    try t.expectApproxEqAbs(reference[0].p2.y, first.c2.y, 1e-12);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<svg") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
}
test "Typst show rules keep frame snapshots and body-local changes isolated" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, translate, fill, label, picture};import geometry.compound;import object.outlines;import text.width;import assertions.assert
        \\words:=typ.module[#let word(s) = {
        \\ strong(s)
        \\ /*
        \\ end
        \\ */
        \\}]
        \\small:=typ.module[#let style(body) = {
        \\ set text(size:10pt)
        \\ body
        \\}]
        \\typ.show small.style
        \\a:=typ[
        \\ #huak.words.word("Same Ω")
        \\]
        \\b:=typ[
        \\ #set text(size:30pt)
        \\ #huak.words.word("Same Ω")
        \\]
        \\c:=typ[
        \\ #huak.words.word("Same Ω")
        \\]
        \\assert(width(a)==width(c))
        \\assert(width(b)>2*width(a))
        \\large:=typ.module[#let style(body) = {
        \\ set text(size:20pt)
        \\ body
        \\}]
        \\d:=block
        \\ typ.show large.style
        \\ return typ[
        \\ #huak.words.word("Same Ω")
        \\]
        \\end
        \\assert(width(d)>1.9*width(a))
        \\assert(width(a)==width(c))
        \\pic:=picture(640, 480)
        \\object.append(pic, object.label(a, (10,20))); object.append(pic, object.label(b, (10,50))); object.append(pic, object.label(d, (10,90)))
        \\p:=compound(outlines(c).paths); object.append(pic, object.fill(p, rgb(0,0,0), translate((100,20))))
        \\raw:=pic.paths
        \\expanded:=outlines(pic).paths
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expectEqual(@as(usize, 4), runtime.frames.items.len);
    const raw = machine.getGlobal("raw").?.list.items();
    const expanded = machine.getGlobal("expanded").?.list.items();
    try t.expect(raw.len > 0);
    try t.expectEqual(raw.len, expanded.len);
    for (raw, expanded) |actual, expected| {
        try t.expectEqualDeep(runtime.path_values.items[expected.handle.index].segments.items, runtime.path_values.items[actual.handle.index].segments.items);
    }
    var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/FontFile") != null);
}
test "native Typst blocks control wrapping and embed code and math without DSL wrappers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const scripts = [_][]const u8{
        \\import paint.{label, picture};import text.{width, height};import assertions.assert
        \\x:=typ[
        \\#block(width:35pt)[#text(size:12pt)[word word word word]]
        \\]
        \\assert(width(x)<=35.1pt); assert(height(x)>20pt); pic:=picture(640, 480); object.append(pic, object.label(x, (10,20)))
        ,
        \\import paint.{label, picture};x:=typ[
        \\#{ let v=3; [#v] }
        \\]
        \\y:=typ[
        \\$frac(1,2)$
        \\]
        \\pic:=picture(640, 480); object.append(pic, object.label(x, (10,20))); object.append(pic, object.label(y, (30,20)))
        ,
        \\import paint.{label, picture};import assertions.assert
        \\typst:=12
        \\assert(typst==12)
        \\x:=typ[
        \\#let s = "first
        \\end
        \\last"
        \\#s
        \\```typ
        \\end
        \\```
        \\#[
        \\end
        \\]
        \\]
        \\pic:=picture(640, 480); object.append(pic, object.label(x, (10,20)))
        ,
        \\import paint.{label, picture};import text.{width, height};import assertions.assert
        \\helpers:=typ.module[#let wrap(body) = strong(body)]
        \\theme:=typ.module[#let style(body) = {set text(size:11pt); body}]
        \\typ.show theme.style
        \\x:=typ[#huak.helpers.wrap[Inline] #("]") `]` /* ] */ #[#{ let v="}"; [#v] }]]
        \\end_text:=typ[
        \\end
        \\]
        \\assert(width(x)>0pt); assert(height(end_text)>0pt)
        \\assert(typ[A].width==width(typ[A]))
        \\items:=[typ[A],typ[B]]; assert(items[0].width>0pt)
        \\blank:=typ.module[]; empty:=typ[]; assert(empty.width>=0pt)
        \\pic:=picture(640, 480); object.append(pic, object.label(typ[#strong[Argument]], (10,20))); after:=7
        \\assert(after==7)
        ,
        \\import math.abs;import paint.{label, picture};import assertions.assert
        \\words:=typ.module[#let word(body) = strong(body)]
        \\theme:=typ.module[#let style(body) = {set text(size:10pt); show "seed": "leaf"; body}]
        \\typ.show theme.style
        \\a:=typ[#huak.words.word[seed]]; b:=typ[#strong[leaf]]
        \\assert(abs(a.width-b.width)<0.000001pt)
        \\large:=typ.module[#let style(body) = {set text(size:20pt); body}]
        \\c:=block
        \\    typ.show large.style
        \\    return typ[#huak.words.word[seed]]
        \\end
        \\assert(c.width>1.9*a.width)
        \\pic:=picture(640, 480); object.append(pic, object.label(a, (10,20))); object.append(pic, object.label(c, (10,50)))
        ,
    };
    for (scripts) |source| {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
    const failures = [_][]const u8{
        "import solver.{unknown, equation};s:=solver(); t:=solver(); x:=unknown(s); y:=unknown(t); equation(s,x,y)",
        "import solver.{unknown, equation, solve, value};s:=solver(); x:=unknown(s); equation(s,x,1); equation(s,x,2); result:=solve(s); value(result,x)",
        \\x:=typ[
        \\#does-not-exist
        \\]
        ,
        "import solver.{unknown, solve, value};s:=solver(); x:=unknown(s); result:=solve(s); value(result,x)",
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
test "labeled typeset elements become anchors in the text's own coordinates" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import assertions.assert
        \\import math.{abs, norm}
        \\import text.anchors
        \\import object.bounds
        \\parts:=typ.module[#let mark(name, body) = [#box($body$)#label(name)]]
        \\m:=typ[$ M = mat(huak.parts.mark("a", a), huak.parts.mark("b", b); huak.parts.mark("c", c), huak.parts.mark("d", d^2)) $]
        \\// Typst lays out matrices column by column.
        \\assert(m.anchors.keys()==["a","c","b","d"])
        \\assert(text.anchors(m).keys()==m.anchors().keys() and anchors(m)==m.anchors)
        \\a:anchor:=m.anchors["a"]
        \\d:=m.anchors["d"]
        \\assert(a.min.x<a.max.x and a.min.y<a.max.y)
        \\assert(norm(a.center-(a.min+a.max)/2)<0.000001pt)
        \\// y points up: the first row lies above the second.
        \\assert(a.position.y>d.position.y and a.center.y>d.center.y and a.center.x<d.center.x)
        \\// Anchors use the coordinates in which object(m) places the text.
        \\box:=bounds(object(m))
        \\for name in m.anchors.keys() do
        \\  entry:anchor:=m.anchors[name]
        \\  assert(entry.min.x>=box[0].x and entry.min.y>=box[0].y and entry.max.x<=box[1].x and entry.max.y<=box[1].y)
        \\end
        \\// Reads share the anchors, but each returns its own dictionary.
        \\assert(m.anchors["a"]==a)
        \\copy_:=m.anchors; copy_["z"]=1
        \\assert(not dict_contains(m.anchors, "z") and len(m.anchors)==4)
        \\inline:=typ[Hi #box[X] <x> and #metadata(1) <meta>]
        \\x:=inline.anchors["x"]
        \\assert(abs(x.position.y)<0.001pt and x.min.y<0.001pt and x.max.y>5pt)
        \\assert(abs(x.position.x-x.min.x)<0.001pt and x.position.x>inline.width/10)
        \\meta:=inline.anchors["meta"]
        \\assert(meta.min==meta.position and meta.max==meta.position and norm(meta.center-meta.position)<0.000001pt)
        \\assert(len(typ[Plain].anchors)==0)
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);

    const failures = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "x:=typ[#box[A] <same> and #box[B] <same>].anchors", .message = "label <same> occurs more than once" },
        .{ .source = "x:=typ[#box[A] <a>].anchors[\"b\"]", .message = "dictionary has no key 'b'" },
    };
    for (failures) |failure| {
        var failing = try compile(&library, failure.source);
        defer failing.deinit();
        var failing_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer failing_runtime.deinit();
        var failing_machine = try l.Machine.init(t.allocator, &failing, failing_runtime.host(), .{});
        defer failing_machine.deinit();
        try t.expectError(error.RuntimeFailed, failing_machine.execute(&.{}));
        const detail = failing_machine.failure.?;
        try t.expect(std.mem.indexOf(u8, detail.text(), failure.message) != null or std.mem.indexOf(u8, detail.native_message, failure.message) != null);
    }
    var diagnostic: ?l.compiler.Diagnostic = null;
    try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, "p:=picture(); x:=p.anchors", "anchors-invalid.huak", .{ .source_parser = .init(&library) }, &diagnostic));
}
test "library and compiled bytecode are reused across isolated native runtime executions" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{circle, bounds, draw, label, picture};import assertions.assert
        \\param n: int=2; pic:=picture(640, 480); p:=circle((30,30),n); object.append(pic, object.draw(p))
        \\box:=pic.bounds(); assert(box[1].x>box[0].x)
        \\t:=typ[
        \\Reusable Ω
        \\]
        \\object.append(pic, object.label(t, (10,10)))
    );
    defer program.deinit();
    for (0..4) |i| {
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        const value = if (i % 2 == 0) "3" else "7";
        _ = try machine.execute(&.{.{ .name = "n", .value = value }});
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(svg.bytes().len > 100);
    }
}

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
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "37%{transform:translate(50px,20px)}") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "2.5s linear both") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "100%{fill:rgb(255,0,0)}") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "0%{opacity:0.2}") != null);
    try t.expectError(error.AnimationRequiresSvg, runtime.render(machine.getGlobal("pic").?, .pdf));
    // Encoding the same immutable scene again doesn't evaluate text again.
    var again = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer again.deinit();
    try t.expectEqualSlices(u8, svg.bytes(), again.bytes());
    try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
}

test "animation snapshots are static pictures of the playback state" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, circle, rectangle, path, fill, picture, bounds};import animation.{timeline, animate, motion};import math.norm;import assertions.assert
        \\// One second into a 4 s loop: phase 0.25.
        \\pic:=picture(160pt,60pt); pic.timeline(4)
        \\faded:=object.append(pic, fill(circle((20pt,30pt),6pt),rgb(0.2,0.4,0.6)))
        \\animate(faded,"opacity",[[0,0.2],[0.5,1],[1,0]])
        \\tinted:=object.append(pic, fill(rectangle((40pt,24pt),12pt,12pt),rgb(1,0,0)))
        \\animate(tinted,"fill",[[0,rgb(1,0,0)],[1,rgb(0,0,1)]])
        \\held:=object.append(pic, fill(circle((80pt,30pt),6pt),rgb(0,0,0)))
        \\animate(held,"opacity",[[0,1],[0.5,0],[1,1]],"discrete")
        \\hidden:=object.append(pic, fill(circle((110pt,30pt),6pt),rgb(0,0,0)))
        \\animate(hidden,"opacity",[[0,1],[0.2,0],[1,0]],"discrete")
        \\still:=animation.snapshot(pic,1)
        \\expected:=picture(160pt,60pt)
        \\object.append(expected, fill(circle((20pt,30pt),6pt),rgb(0.2,0.4,0.6,0.6)))
        \\object.append(expected, fill(rectangle((40pt,24pt),12pt,12pt),rgb(0.75,0,0.25)))
        \\object.append(expected, fill(circle((80pt,30pt),6pt),rgb(0,0,0)))
        \\// A symmetric easing curve passes its midpoint at half time.
        \\curved:=picture(40pt,40pt); curved.timeline(2)
        \\dot:=object.append(curved, fill(circle((20pt,20pt),6pt),rgb(0,0,0)))
        \\animate(dot,"opacity",[[0,0],[1,1]],[0.42,0,0.58,1])
        \\curved_still:=animation.snapshot(curved,1)
        \\curved_expected:=picture(40pt,40pt)
        \\object.append(curved_expected, fill(circle((20pt,20pt),6pt),rgb(0,0,0,0.5)))
        \\// A quarter cycle ahead, one second into four: halfway.
        \\phased:=picture(40pt,40pt); phased.timeline(4)
        \\lit:=object.append(phased, fill(circle((20pt,20pt),6pt),rgb(0,0,0)))
        \\animate(lit,"opacity",[[0,0],[1,1]],phase:0.25)
        \\phased_still:=animation.snapshot(phased,1)
        \\phased_expected:=picture(40pt,40pt)
        \\object.append(phased_expected, fill(circle((20pt,20pt),6pt),rgb(0,0,0,0.5)))
        \\mixed:=picture(40pt,40pt); mixed.timeline(2)
        \\kept:=object.append(mixed, fill(circle((20pt,20pt),6pt),rgb(0,0,0)))
        \\animate(kept,"opacity",[[0,0],[1,1]],smil:true)
        \\// Wrappers nest in declaration order: translate outside scale.
        \\moving:=picture(200pt,200pt); moving.timeline(2,false)
        \\square:=object.append(moving, fill(rectangle((0pt,0pt),10pt,10pt),rgb(0,0,0)))
        \\animate(square,"translate",[[0,(0pt,0pt)],[1,(100pt,0pt)]])
        \\animate(square,"scale",[[0,(1,1)],[1,(3,3)]])
        \\half:=bounds(animation.snapshot(moving,1))
        \\assert(half[0]==(50pt,0pt) and half[1]==(70pt,20pt))
        \\// A single run holds its last keys after the end.
        \\frozen:=bounds(animation.snapshot(moving,9))
        \\assert(frozen[0]==(100pt,0pt) and frozen[1]==(130pt,30pt))
        \\turning:=picture(200pt,200pt); turning.timeline(2)
        \\bar:=object.append(turning, fill(rectangle((10pt,0pt),10pt,10pt),rgb(0,0,0)))
        \\animate(bar,"rotate",[[0,0deg],[1,180deg]])
        \\turned:=bounds(animation.snapshot(turning,1))
        \\assert(norm(turned[0]-(-10pt,10pt))<0.000001pt and norm(turned[1]-(0pt,20pt))<0.000001pt)
        \\travel:=picture(200pt,200pt); travel.timeline(4)
        \\ball:=object.append(travel, fill(circle((0pt,0pt),2pt),rgb(0,0,0)))
        \\motion(ball,path((0pt,0pt),(0pt,80pt)),[[0,0],[1,1]],"none")
        \\placed:=bounds(animation.snapshot(travel,1))
        \\assert(norm(placed[0]-(-2pt,18pt))<0.000001pt and norm(placed[1]-(2pt,22pt))<0.000001pt)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][2][]const u8{ .{ "still", "expected" }, .{ "curved_still", "curved_expected" }, .{ "phased_still", "phased_expected" } }) |pair| {
            var still = try runtime.render(machine.getGlobal(pair[0]).?, .svg);
            defer still.deinit();
            var expected = try runtime.render(machine.getGlobal(pair[1]).?, .svg);
            defer expected.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), still.bytes());
            try t.expect(std.mem.indexOf(u8, still.bytes(), "<animate") == null);
        }
        // The animated source still needs SVG; its snapshot exports as PDF.
        try t.expectError(error.AnimationRequiresSvg, runtime.render(machine.getGlobal("pic").?, .pdf));
        var pdf = try runtime.render(machine.getGlobal("still").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        // The easing list reaches CSS as one cubic-bezier timing curve.
        var curved = try runtime.render(machine.getGlobal("curved").?, .svg);
        defer curved.deinit();
        try t.expect(std.mem.indexOf(u8, curved.bytes(), " 2s cubic-bezier(0.42,0,0.58,1) infinite") != null);
        // A phase starts the loop partway: an inline delay over its start state.
        var phased = try runtime.render(machine.getGlobal("phased").?, .svg);
        defer phased.deinit();
        try t.expect(std.mem.indexOf(u8, phased.bytes(), "opacity=\"0.25\" class=\"huak-a") != null);
        try t.expect(std.mem.indexOf(u8, phased.bytes(), "\" style=\"animation-delay:-1s\"") != null);
        // A track marked smil plays as SMIL and needs no stylesheet.
        var mixed = try runtime.render(machine.getGlobal("mixed").?, .svg);
        defer mixed.deinit();
        try t.expect(std.mem.indexOf(u8, mixed.bytes(), "<animate attributeName=\"opacity\" values=\"0;1\" dur=\"2s\" repeatCount=\"indefinite\"/>") != null);
        try t.expect(std.mem.indexOf(u8, mixed.bytes(), "<style>") == null);
    }
    const failures = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "pic:=picture(40pt,40pt); pic.timeline(1)\ngroup:=object.append(pic, picture())\nobject.append(group, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(group,\"opacity\",[[0,0.5],[1,0.5]])\nstill:=animation.snapshot(pic,0)", .message = "Typst groups have no opacity" },
        .{ .source = "pic:=picture(40pt,40pt); pic.timeline(1)\ndot:=object.append(pic, filldraw(circle((9pt,9pt),3pt),rgb(0,0,0),pen(rgb(1,0,0),1pt)))\nanimate(dot,\"opacity\",[[0,0.5],[1,1]])\nstill:=animation.snapshot(pic,0)", .message = "Typst groups have no opacity" },
        .{ .source = "pic:=picture(40pt,40pt); pic.timeline(1)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"stroke\",[[0,rgb(0,0,0)],[1,rgb(1,0,0)]])\nstill:=animation.snapshot(pic,0.5)", .message = "already has a stroke" },
        .{ .source = "pic:=picture(40pt,40pt)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"opacity\",[[0,0],[1,1]])\nstill:=animation.snapshot(pic,0)", .message = "MissingTimeline" },
        .{ .source = "pic:=picture(40pt,40pt); pic.timeline(1)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"opacity\",[[0,0],[1,1]])\nstill:=animation.snapshot(pic,-1)", .message = "InvalidTiming" },
        .{ .source = "pic:=picture(40pt,40pt)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"opacity\",[[0,0],[1,1]],[0.2,0,1.5,1])", .message = "InvalidEasing" },
    };
    for (failures) |failure| {
        const input = try std.mem.concat(t.allocator, u8, &.{ "import paint.{rgb, circle, fill, filldraw, pen, picture};import animation.{timeline, animate}\n", failure.source });
        defer t.allocator.free(input);
        var program = try compileModulesOptimized(&library, input, &.{}, false);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const detail = machine.failure.?;
        const reported = std.mem.indexOf(u8, detail.text(), failure.message) != null or std.mem.indexOf(u8, detail.native_message, failure.message) != null;
        if (!reported) std.debug.print("snapshot failure: {s} / {s}\n", .{ detail.text(), detail.native_message });
        try t.expect(reported);
    }
}

test "path queries clipping picture copies and animation motion reuse core operations" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.norm;import paint.{rgb, translate, circle, path, joined, draw, fill, picture, append};import geometry.{point_at, tangent_at, intersections, clipped};import animation.{timeline, motion};import assertions.assert
        \\pic:=picture(100,100)
        \\p:=path((0,0),(10,0)); q:=path((10,0),(20,0))
        \\joined_path:=joined(p,q)
        \\assert(point_at(joined_path,1.5)==(15pt,0))
        \\assert(norm(tangent_at(joined_path,0.5))>0pt)
        \\assert(len(clipped(joined_path,(5,-1),(15,1)))==2)
        \\cross:=intersections(p,path((5,-5),(5,5)))
        \\assert(len(cross)==1); assert(norm(cross[0]-(5pt,0))<0.00001pt)
        \\child:=picture(640, 480); object.append(child, object.draw(joined_path)); pic.append(copy(child)); pic.append(copy(child), translate((0,20)))
        \\ball:=object.append(pic, object.fill(circle((0,0),2), rgb(0,0,1)))
        \\pic.timeline(1); motion(ball,joined_path,[[0,0],[1,1]],"none")
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "offset-path:path(") != null);
}

test "runtime copies inputs before lazy engine creation and retains native diagnostic" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var key = [_]u8{'n'};
    var data = [_]u8{ 'c', 'a', 'f', 'e' };
    const inputs = [_]typst.Input{.{ .key = &key, .value = &data }};
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{ .inputs = &inputs });
    defer runtime.deinit();
    key[0] = 'x';
    @memset(&data, 'z');
    var program = try compile(&library,
        \\import paint.{label, picture};t:=typ[
        \\#{ assert(sys.inputs.n == "cafe"); sys.inputs.n }
        \\]
        \\pic:=picture(640, 480); object.append(pic, object.label(t, (10,10)))
    );
    defer program.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
    defer pdf.deinit();
    try t.expect(pdf.bytes().len > 500);
}
test "deep or exponentially shared lists have bounded formatting work" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const scripts = [_][]const u8{
        "a:any:=[]; for i in 1:300 do; a=[a]; end; print(a)",
        "a:any:=[1]; for i in 1:30 do; a=[a,a]; end; str(a)",
    };
    for (scripts) |source| {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(machine.failure != null);
    }
    const text = try l.Runtime.formatValue(t.allocator, .{ .vec2 = .{ .x = 1e308, .y = 1e-308 } });
    defer t.allocator.free(text);
    try t.expect(text.len > 0);
}

test "a shown style preserves raw markup with embedded math code and trailing comments" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.abs;import paint.{picture, label};import text.width;import assertions.assert
        \\plain:=typ[
        \\\[
        \\]
        \\math_plain:=typ[
        \\$x // trailing comment
        \\$
        \\]
        \\code_plain:=typ[
        \\#{ 1 // trailing comment
        \\}
        \\]
        \\words:=typ.module[#let strong_word(s) = strong(s)]
        \\theme:=typ.module[#let style(body) = {
        \\ set text(size:11pt)
        \\ show "before": "after"
        \\ body
        \\}]
        \\pic:=picture(640, 480)
        \\block
        \\typ.show theme.style
        \\bracket:=typ[
        \\\[
        \\]
        \\math_shared:=typ[
        \\$x // trailing comment
        \\$
        \\]
        \\code_shared:=typ[
        \\#{ 1 // trailing comment
        \\}
        \\]
        \\assert(abs(width(bracket)-width(plain))<0.00001pt)
        \\assert(abs(width(math_shared)-width(math_plain))<0.00001pt)
        \\assert(abs(width(code_shared)-width(code_plain))<0.00001pt)
        \\rich:=typ[
        \\#huak.words.strong_word[Hello] before
        \\]
        \\object.append(pic, object.label(rich, (10,20))); object.append(pic, object.label(bracket, (10,40)))
        \\end
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
}

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
    try t.expect(std.mem.indexOf(u8, animated.bytes(), "@keyframes ") != null);
    try t.expect(std.mem.indexOf(u8, animated.bytes(), " 1.25s ") != null);
    try t.expect(std.mem.indexOf(u8, static.bytes(), "<style>") == null);
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "default output retains its picture while named outputs read the final binding" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{label, picture};import picture.canvas;export first:=picture(80,40)
        \\default first
        \\alias:=first
        \\export alias
        \\alias.canvas(90,45)
        \\first=picture(120,70)
        \\t:=typ[
        \\Shared exported text Ω
        \\]
        \\object.append(alias, object.label(t, (5,20))); object.append(first, object.label(t, (5,20)))
    );
    defer program.deinit();
    try t.expectEqual(@as(usize, 2), program.exports.len);
    for (program.exports) |exposed| {
        try t.expect(std.mem.eql(u8, exposed.name, "first") or std.mem.eql(u8, exposed.name, "default") or std.mem.eql(u8, exposed.name, "alias"));
        try t.expectEqualStrings(exposed.name, program.global_names[exposed.target.global]);
    }
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const original = machine.getGlobal("<default>").?;
    const alias = machine.getGlobal("alias").?;
    const first = machine.getGlobal("first").?;
    try t.expectEqual(original.object, alias.object);
    try t.expect(!std.meta.eql(original.object, first.object));
    try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
    var old_svg = try runtime.render(original, .svg);
    defer old_svg.deinit();
    var new_svg = try runtime.render(first, .svg);
    defer new_svg.deinit();
    var pdf = try runtime.render(alias, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, old_svg.bytes(), "viewBox=\"0 0 90 45\"") != null);
    try t.expect(std.mem.indexOf(u8, new_svg.bytes(), "viewBox=\"0 0 120 70\"") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
}

const ModuleSource = struct { name: []const u8, source: []const u8 };
fn linkedModule(program: *const l.bytecode.Program, name: []const u8) !l.bytecode.Module {
    var found: ?l.bytecode.Module = null;
    for (program.modules) |module| {
        if (!std.mem.eql(u8, module.name, name)) continue;
        try t.expect(found == null);
        found = module;
    }
    return found orelse error.MissingModule;
}

const ModuleResolver = struct {
    sources: []const ModuleSource,

    fn resolve(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) !l.compiler.ResolvedSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        const name = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer).?, path });
        for (self.sources) |source| {
            if (std.mem.eql(u8, source.name, name)) return .{ .name = name, .source = try allocator.dupe(u8, source.source) };
        }
        return error.ModuleNotFound;
    }
};

fn compileModules(library: *typst.Library, source: []const u8, sources: []const ModuleSource) !l.bytecode.Program {
    return compileModulesOptimized(library, source, sources, true);
}

fn compileModulesOptimized(library: *typst.Library, source: []const u8, sources: []const ModuleSource, optimize: bool) !l.bytecode.Program {
    var resolver: ModuleResolver = .{ .sources = sources };
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "/native/main.huak", .{
        .source_parser = .init(library),
        .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } },
        .optimize = optimize,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}: {s}\n", .{ detail.fileName() orelse "/native/main.huak", detail.text() });
        return err;
    };
}

const scoped_modules = [_]ModuleSource{
    .{ .name = "/native/outer.huak", .source =
    \\print("outer")
    \\export value:=10
    \\export fn compute(input:int)->int return value+input end
    \\export fn ordinary(a:int,b:int)->int return 10*a+b end
    \\fn secret(input:int)->int return input end
    },
    .{ .name = "/native/inner.huak", .source =
    \\print("inner")
    \\export value:=20
    \\export fn compute(input:int)->int return value+input end
    },
    .{ .name = "/native/dormant.huak", .source = "print(\"must not initialize\")\nexport value:=99" },
};

test "lexical imports restore namespaces and members across executable blocks" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import drawing.drawing
        \\import paint.{path, draw, picture};import assertions.assert
        \\param mode:int=0
        \\import "outer.huak" as math
        \\import "outer.huak".{value as chosen,compute as choose}
        \\import "outer.huak".value as dual
        \\import "outer.huak".ordinary as dual_call
        \\assert(dual==10 and dual_call(2,3)==23)
        \\if true then
        \\    import "inner.huak".value as dual
        \\    assert(dual==20 and dual_call(2,3)==23)
        \\end
        \\fn from_function(input:int)->int
        \\    import "inner.huak" as math
        \\    import "inner.huak".value as chosen
        \\    if input>0 then
        \\        import "outer.huak" as math
        \\        return math.compute(input)+chosen
        \\    end
        \\    return math.compute(input)+chosen
        \\end
        \\fn data_shadow()->int math:=7; return math end
        \\assert(from_function(2)==32 and from_function(0)==40 and data_shadow()==7)
        \\branch_result:=0; if mode==0 then
        \\    import "inner.huak".compute as choose
        \\    branch_result=choose(1)
        \\elseif mode==1 then
        \\    import "outer.huak".compute as choose
        \\    branch_result=choose(1)
        \\else
        \\    import "inner.huak".compute as choose
        \\    branch_result=choose(2)
        \\end
        \\recorded:=[]
        \\for i in 1:2 do
        \\    import "inner.huak".compute as choose
        \\    recorded+=choose(i)
        \\end
        \\counter:=0
        \\while counter<2 do
        \\    import "inner.huak" as math
        \\    recorded+=math.compute(counter)
        \\    counter=counter+1
        \\end
        \\if false then import "dormant.huak" as absent end
        \\export pic:=picture(80,40)
        \\drawing pic do
        \\    import "inner.huak" as math
        \\    +draw path((0,0),(math.value,10))
        \\end
        \\assert(recorded==[21,22,20,21])
        \\assert(math.value==10 and chosen==10 and choose(0)==10 and dual==10)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &scoped_modules, optimize);
        defer program.deinit();
        for ([_]i64{ 21, 11, 22 }, 0..) |expected, mode| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            const value = try std.fmt.allocPrint(t.allocator, "{d}", .{mode});
            defer t.allocator.free(value);
            _ = try machine.execute(&.{.{ .name = "mode", .value = value }});
            try t.expectEqual(expected, machine.getGlobal("branch_result").?.int);
            try t.expectEqualStrings("outer\ninner\n", runtime.printedText());
            if (mode == 0) {
                var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
                defer svg.deinit();
                try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 80 40\"") != null);
                try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
            }
        }
    }
}

test "lexical callable roles restore precedence and nonprefix shadowing" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{.{ .name = "/native/operators.huak", .source =
        \\mixfix(compute) compute _ in unary
        \\export fn compute(input:int)->int return 2*input end
        \\export fn ordinary(a:int,b:int)->int return 10*a+b end
        \\export value:=10
    }};
    const source =
        \\import drawing.drawing
        \\import paint.{rgb, rectangle, fill, picture};import assertions.assert
        \\import "operators.huak".compute as act
        \\fn join_values(a:int,b:int)->int return 10*a+b end
        \\mixfix(join_values) _ join_values _ in addition
        \\fn only_here(value:int)->int return 10+value end
        \\fn local_prefix(value:int)->int
        \\    mixfix(only_here) only_here _ in unary
        \\    return only_here value
        \\end
        \\assert(compute 3+1==7)
        \\assert(1+2 join_values 3==33)
        \\if true then
        \\    import "operators.huak".value as act
        \\    captured:=[act]
        \\    assert(captured==[10])
        \\end
        \\if true then
        \\    import "operators.huak".ordinary as act
        \\    mixfix(act) _ act _ in addition
        \\    mixfix(join_values) _ join_values _ in multiplication
        \\    assert(act (2,3)==23)
        \\    assert(2 act 3==23)
        \\    assert(1+2 join_values 3==24)
        \\end
        \\assert(compute 3+1==7 and 1+2 join_values 3==33)
        \\assert(local_prefix(2)==12 and only_here(2)==12)
        \\total:=0
        \\for i in 1:2 do
        \\    mixfix(only_here) only_here _ in unary
        \\    total=total+only_here i
        \\end
        \\counter:=0
        \\while counter<2 do
        \\    mixfix(only_here) only_here _ in unary
        \\    total=total+only_here counter
        \\    counter=counter+1
        \\end
        \\assert(total==44 and only_here(3)==13)
        \\fn paint_mark(curve:path)->object return fill(curve, rgb(1,0,0)) end
        \\pic:=picture(40,30)
        \\drawing pic do
        \\    mixfix(paint_mark) paint_mark _ in logical_or
        \\    +paint_mark rectangle((1,1),5,5)
        \\end
        \\object.append(pic,paint_mark(rectangle((10,1),5,5)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(i64, 44), machine.getGlobal("total").?.int);
        const target = machine.getGlobal("pic").?;
        try t.expectEqual(@as(usize, 2), try scene.childCount(target));
    }
}

test "block imports retain the settings of each text source module" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{
        .{ .name = "/native/large.huak", .source = "theme:=typ.module[#let style(body) = {set text(size:24pt); body}]\ntyp.show theme.style\nexport caption:=typ[Scope Ω]" },
        .{ .name = "/native/small.huak", .source = "theme:=typ.module[#let style(body) = {set text(size:8pt); body}]\ntyp.show theme.style\nexport caption:=typ[Scope Ω]" },
    };
    const source =
        \\import math.abs;import assertions.assert
        \\theme:=typ.module[#let style(body) = {set text(size:12pt); body}]
        \\typ.show theme.style
        \\before:=typ[Scope Ω]
        \\fn captions()->list
        \\    import "large.huak".caption as label
        \\    large:=label; small:=label
        \\    if true then
        \\        import "small.huak".caption as label
        \\        small=label
        \\    end
        \\    restored:=label
        \\    own:=typ[Scope Ω]
        \\    return [large,small,restored,own]
        \\end
        \\texts:=captions()
        \\outside:=typ[Scope Ω]
        \\assert(texts[0]==texts[2])
        \\assert(texts[0].width>1.9*before.width)
        \\assert(texts[1].width<0.8*before.width)
        \\assert(abs(texts[3].width-before.width)<0.000001pt)
        \\assert(abs(outside.width-before.width)<0.000001pt)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
}

test "scoped bindings cannot escape siblings or bypass privacy conflicts and export rules" {
    const cases = [_]struct { source: []const u8, message: ?[]const u8 = null }{
        .{ .source = "missing=1", .message = "not an assignable value" },
        .{ .source = "value:=1;value:=2", .message = "duplicate declaration" },
        .{ .source = "if true then value:=1 end;print(value)", .message = "unknown name" },
        .{ .source = "for i in 1:2 do value=value+1;value:=0 end", .message = "before its declaration" },
        .{ .source = "for i in 1:2 do value:=value+1 end", .message = "unknown name" },
        .{ .source = "fn f(value:int)->int value:=2;return value end", .message = "duplicate declaration" },
        .{ .source = "if true then import \"outer.huak\".compute as member end\nbad:=member(1)", .message = "member" },
        .{ .source = "if true then import \"outer.huak\" as local_math else bad:=local_math.value end", .message = "local_math" },
        .{ .source = "for i in 1:2 do import \"outer.huak\".compute as member end\nbad:=member(1)", .message = "member" },
        .{ .source = "while false do import \"outer.huak\".compute as member end\nbad:=member(1)", .message = "member" },
        .{ .source = "import drawing.drawing;drawing picture(640, 480) do import \"outer.huak\".compute as member end\nbad:=member(1)", .message = "member" },
        .{ .source = "fn run()->int import \"outer.huak\".compute as member;return member(1) end\nbad:=member(1)", .message = "member" },
        .{ .source = "if false then import \"outer.huak\".secret end", .message = "secret" },
        .{ .source = "if true then import \"outer.huak\" as same;import \"inner.huak\" as same end", .message = "same" },
        .{ .source = "if true then import \"outer.huak\".compute as same;import \"inner.huak\".compute as same end", .message = "same" },
        .{ .source = "fn f(value:int)->int return value end\nif true then mixfix(f) f _ in unary;mixfix(f) f _ in unary end", .message = "f" },
        .{ .source = "fn f(value:int)->int return value end\nif true then mixfix(f) f _ in unary;inside:=f 2 end\nbad:=f 3" },
        .{ .source = "fn f(a:int,b:int)->int return a+b end\nfor i in 1:1 do mixfix(f) _ f _ in addition;inside:=1 f 2 end\nbad:=1 f 2" },
        .{ .source = "if true then export hidden:=1 end", .message = "export" },
        .{ .source = "fn run()->int export hidden:=1;return hidden end", .message = "export" },
        .{ .source = "if true then export fn hidden()->int return 1 end end" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        var resolver: ModuleResolver = .{ .sources = &scoped_modules };
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, case.source, "/native/main.huak", .{ .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } }, .optimize = optimize }, &diagnostic));
        try t.expect(diagnostic != null);
        if (case.message) |message| {
            if (std.mem.indexOf(u8, diagnostic.?.text(), message) == null) {
                std.debug.print("scope diagnostic for:\n{s}\nexpected '{s}', got '{s}'\n", .{ case.source, message, diagnostic.?.text() });
                return error.UnexpectedScopeDiagnostic;
            }
        }
    };
}

test "scoped imports must be declared before a function uses their members" {
    const source =
        \\fn marker()->int print("argument"); return 1 end
        \\fn early()->int
        \\    result:=helper(marker())
        \\    import "outer.huak".compute as helper
        \\    return result
        \\end
        \\answer:=early()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var resolver: ModuleResolver = .{ .sources = &scoped_modules };
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, source, "/native/main.huak", .{ .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } }, .optimize = optimize }, &diagnostic));
        try t.expect(diagnostic != null);
        try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), "helper") != null);
    }
}

test "data parameters and loop bindings prevent fallback to shadowed callables" {
    const cases = [_]struct { source: []const u8, name: []const u8 }{
        .{ .source = "import math.sin\nsin:=3\nresult:=sin(0)", .name = "sin" },
        .{ .source = "import math.sin\nfn measured(sin:float)->float return sin(0) end", .name = "sin" },
        .{ .source = "fn measured(print:int) print(0) end", .name = "print" },
        .{ .source = "picture:=3\nresult:=picture(640, 480)", .name = "picture" },
        .{ .source = "import \"outer.huak\".compute as helper\nhelper:=3\nresult:=helper(1)", .name = "helper" },
        .{ .source = "import \"outer.huak\".compute as helper\nif true then import \"inner.huak\".value as helper; result:=helper(1) end", .name = "helper" },
        .{ .source = "import \"outer.huak\".compute as item\nfor item in 1:1 do result:=item(1) end", .name = "item" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        var resolver: ModuleResolver = .{ .sources = &scoped_modules };
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, case.source, "/native/main.huak", .{ .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } }, .optimize = optimize }, &diagnostic));
        try t.expect(diagnostic != null);
        try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.name) != null);
        try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), "not callable") != null);
    };
}

test "qualified domain calls remain usable when data shadows an imported function" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library,
            \\import math.sin
            \\sin:=2
            \\direct:=math.sin(0)
            \\fn measured(sin:float)->float return math.sin(sin) end
            \\by_parameter:=measured(0)
        , &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(i64, 2), machine.getGlobal("sin").?.int);
        try t.expectEqual(@as(f64, 0), machine.getGlobal("direct").?.number);
        try t.expectEqual(@as(f64, 0), machine.getGlobal("by_parameter").?.number);
    }
}

test "selected and reexported function aliases retain native operators and precedence groups" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const modules = [_]ModuleSource{
        .{ .name = "/native/operators.huak", .source =
        \\import paint.{translate, scale, transformed};precedence placement below addition; above path; associativity left end
        \\amount:=1+2*3
        \\fn adjusted(value:int)->int
        \\    correction:=1+2*3
        \\    return value+correction
        \\end
        \\export placement, amount, adjusted
        \\export fn enlarged(curve:path,factor:float)->path
        \\    return transformed(curve,scale(factor))
        \\end
        \\mixfix(enlarged) _ enlarged _ in placement
        \\export fn relocated(curve:path,offset:vec2)->path
        \\    return transformed(curve,translate(offset))
        \\end
        \\mixfix(relocated) _ relocated _ in placement
        \\export fn doubled(value:float)->float return 2*value end
        \\mixfix(doubled) doubled _ in unary
        },
        .{ .name = "/native/bridge.huak", .source =
        \\import "operators.huak".{placement as order, enlarged as resized, relocated as moved, doubled as twice, amount, adjusted}
        \\export order, resized, moved, twice, amount, adjusted
        },
    };
    const source =
        \\import drawing.drawing
        \\import math.abs;import paint.{translate, circle, transformed, bounds, draw, picture};import assertions.assert
        \\import "bridge.huak".{order as affine, resized as grow, moved as move_curve, twice as double_value, amount as base, adjusted as add_base}
        \\precedence finishing below affine; above path; associativity left end
        \\fn nudged(curve:path,offset:vec2)->path return transformed(curve,translate(offset)) end
        \\mixfix(nudged) _ nudged _ in finishing
        \\base_curve:=circle((0,0),5)
        \\curve:=base_curve enlarged 1+1 relocated (20,30) nudged (3,4)
        \\ordinary:=nudged(move_curve(grow(base_curve,2),(20,30)),(3,4))
        \\assert(curve.bounds()==ordinary.bounds())
        \\assert(abs(curve.bounds()[0].x-13pt)<0.000001pt)
        \\assert(abs(curve.bounds()[1].y-44pt)<0.000001pt)
        \\assert(doubled 3^2+1==19)
        \\assert(double_value(3^2)+1==19)
        \\assert(base==7 and add_base(5)==12)
        \\export grow, double_value, affine
        \\export preview:=picture(120,80)
        \\drawing preview do +draw curve end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &modules, optimize);
        defer program.deinit();
        for (modules) |module| _ = try linkedModule(&program, module.name);
        var checked_fold = false;
        for (program.functions) |function| if (std.mem.eql(u8, function.name, "adjusted")) {
            var multiplications: usize = 0;
            for (function.code) |instruction| if (instruction.op == .multiply) {
                multiplications += 1;
            };
            try t.expectEqual(@as(usize, if (optimize) 0 else 1), multiplications);
            checked_fold = true;
        };
        try t.expect(checked_fold);
        var checked_leading = false;
        var checked_head = false;
        var checked_group = false;
        for (program.exports) |exposed| {
            if (std.mem.eql(u8, exposed.name, "grow")) checked_leading = exposed.target == .function and exposed.mixfix[1] != null;
            if (std.mem.eql(u8, exposed.name, "double_value")) checked_head = exposed.target == .function and exposed.mixfix[0] != null;
            if (std.mem.eql(u8, exposed.name, "affine")) checked_group = exposed.target == .precedence;
        }
        try t.expect(checked_leading and checked_head and checked_group);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var svg = try runtime.render(machine.getGlobal("preview").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 120 80\"") != null);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    }
}

test "namespace wildcard and selected bindings share module initialization and live mutable exports" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{.{ .name = "/native/shared.huak", .source =
        \\import drawing.drawing
        \\import paint.{draw, picture};print("shared initialized")
        \\export items:=[0]
        \\export canvas:=picture(70,35)
        \\original_items:=items
        \\original_canvas:=canvas
        \\export original_items, original_canvas
        \\items=[1]
        \\canvas=picture(90,45)
        \\export fn advance()
        \\    items+=2
        \\    drawing canvas do +draw (1,2)--(20,10) end
        \\end
        \\export fn finish()
        \\    items+=4
        \\    drawing canvas do +draw (2,3)--(30,20) end
        \\end
    }};
    const source =
        \\import assertions.assert
        \\import "shared.huak"
        \\import "./shared.huak".*
        \\import "shared.huak".{items as readings,canvas as sheet,advance as change,finish as refresh}
        \\assert(original_items==[0] and items==[1])
        \\assert(original_canvas!=sheet and sheet==shared.canvas)
        \\readings+=3
        \\change()
        \\assert(items==[1,3,2] and readings==shared.items)
        \\snapshot:=[];snapshot+=readings
        \\old_canvas:=sheet
        \\assert(old_canvas==canvas and canvas==shared.canvas)
        \\refresh()
        \\assert(readings==[1,3,2,4] and items==shared.items)
        \\assert(snapshot==[1,3,2])
        \\assert(sheet==canvas and canvas==shared.canvas and old_canvas==sheet)
        \\fn local_count(items:list)->int return len(items) end
        \\assert(local_count([0])==1)
        \\export preview:=shared.canvas
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &sources, optimize);
        defer program.deinit();
        const shared = try linkedModule(&program, "/native/shared.huak");
        for ([_][2][]const u8{ .{ "items", "readings" }, .{ "canvas", "sheet" } }) |names| {
            var original_global: ?u32 = null;
            for (shared.exports) |exposed| if (std.mem.eql(u8, exposed.name, names[0])) {
                original_global = exposed.target.global;
            };
            try t.expect(original_global != null);
            var alias_loaded = false;
            for (program.functions[program.entry].code) |instruction| {
                if (instruction.op != .load_global) continue;
                const expression = source[instruction.span.start..instruction.span.end];
                if (std.mem.eql(u8, expression, names[1])) {
                    try t.expectEqual(original_global.?, instruction.a);
                    alias_loaded = true;
                }
            }
            try t.expect(alias_loaded);
        }
        for (0..2) |_| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try execute(&machine);
            try t.expectEqualStrings("shared initialized\n", runtime.printedText());
            try t.expectEqual(@as(usize, 2), scene.canvases(&runtime));
            const preview = machine.getGlobal("preview").?;
            try t.expectEqual(@as(usize, 2), try scene.childCount(preview));
            var svg = try runtime.render(preview, .svg);
            defer svg.deinit();
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 90 45\"") != null);
        }
    }
}

test "selection privacy conflicts and invalid exported bodies survive optimization" {
    const sources = [_]ModuleSource{
        .{ .name = "/native/private.huak", .source =
        \\precedence private_order below addition; above path end
        \\mixfix(secret) secret _ in unary
        \\fn secret(value:int)->int return value end
        \\fn step(left:int,right:int)->int return left+right end
        \\mixfix(step) _ step _ in private_order
        \\value:=7
        \\export value,step
        },
        .{ .name = "/native/other.huak", .source = "export value:=8" },
        .{ .name = "/native/invalid.huak", .source =
        \\export fn broken()->int
        \\    if false then return unknown_value end
        \\    return 1
        \\end
        },
    };
    const cases = [_]struct { source: []const u8, name: []const u8 }{
        .{ .source = "import \"private.huak\".secret", .name = "secret" },
        .{ .source = "import \"private.huak\" as space\nanswer:=space.secret(2)", .name = "secret" },
        .{ .source = "import \"private.huak\".private_order", .name = "private_order" },
        .{ .source = "import \"private.huak\".*\nanswer:=secret(2)", .name = "secret" },
        .{ .source = "import \"private.huak\".{value as same,step as same}", .name = "same" },
        .{ .source = "import \"private.huak\".value\nvalue:=1", .name = "value" },
        .{ .source = "import \"private.huak\".step as calculate\nfn calculate()->int return 0 end", .name = "calculate" },
        .{ .source = "import \"private.huak\" as space\nfn space()->int return 0 end", .name = "space" },
        .{ .source = "import \"private.huak\".value\nimport \"other.huak\".value", .name = "value" },
        .{ .source = "value:=1\nexport value,value", .name = "value" },
        .{ .source = "import \"invalid.huak\".broken\nanswer:=1+2*3", .name = "unknown_value" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        var resolver: ModuleResolver = .{ .sources = &sources };
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, case.source, "/native/main.huak", .{
            .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } },
            .optimize = optimize,
        }, &diagnostic));
        try t.expect(diagnostic != null);
        try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.name) != null);
        if (std.mem.eql(u8, case.name, "unknown_value")) try t.expectEqualStrings("/native/invalid.huak", diagnostic.?.fileName().?);
    };
}

test "module namespaces share native frames while isolating Typst show rules by function source" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const imported_source =
        \\import paint.{label, picture}
        \\theme:=typ.module[#let style(body) = {
        \\ set text(size:24pt)
        \\ body
        \\}]
        \\typ.show theme.style
        \\export caption:=typ[
        \\Same Ω
        \\]
        \\export tile:=picture(200,80)
        \\object.append(tile, object.label(caption, (5,30)))
        \\fn make_caption()->text
        \\ return typ[
        \\Same Ω
        \\]
        \\end
        \\export make_caption
    ;
    var program = try compileModules(&library,
        \\import math.abs;import paint.{label, picture, append};import assertions.assert
        \\theme:=typ.module[#let style(body) = {
        \\ set text(size:8pt)
        \\ body
        \\}]
        \\typ.show theme.style
        \\before:=typ[
        \\Same Ω
        \\]
        \\import "typography.huak" as typography
        \\after:=typ[
        \\Same Ω
        \\]
        \\assert(abs(before.width-after.width)<0.000001pt)
        \\child:=typography.make_caption()
        \\assert(child.width>2.9*before.width)
        \\assert(abs(child.width-typography.caption.width)<0.000001pt)
        \\last:=typ[
        \\Same Ω
        \\]
        \\assert(abs(before.width-last.width)<0.000001pt)
        \\export page:=picture(320,180)
        \\page.append(copy(typography.tile))
        \\object.append(page, object.label(before, (5,110))); object.append(page, object.label(child, (5,160)))
    , &.{.{ .name = "/native/typography.huak", .source = imported_source }});
    defer program.deinit();
    _ = try linkedModule(&program, "/native/typography.huak");
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expectEqual(@as(usize, 5), runtime.frames.items.len);
    const page = machine.getGlobal("page").?;
    var svg = try runtime.render(page, .svg);
    defer svg.deinit();
    var pdf = try runtime.render(page, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 320 180\"") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    try t.expectEqual(@as(usize, 5), runtime.frames.items.len);
}

test "linked module initialization is shared within a run and reset for a reused Program" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{
        .{ .name = "/native/shared.huak", .source =
        \\import paint.picture;print("shared initialized")
        \\export canvas:=picture(70,35)
        },
        .{ .name = "/native/left.huak", .source =
        \\import paint.{rgb, rectangle, fill};import "shared.huak" as shared
        \\object.append(shared.canvas, object.fill(rectangle((1,1),4,4), rgb(1,0,0)))
        \\export image:=shared.canvas
        },
        .{ .name = "/native/right.huak", .source =
        \\import "./shared.huak" as shared
        \\export image:=shared.canvas
        },
    };
    var program = try compileModules(&library,
        \\import paint.bounds;import assertions.assert
        \\import "left.huak" as left
        \\import "right.huak" as right
        \\import "./shared.huak" as direct
        \\assert(left.image==right.image); assert(left.image==direct.canvas)
        \\assert(direct.canvas.bounds()[0]==(1pt,1pt))
        \\export scene:=right.image
    , &sources);
    defer program.deinit();
    for (sources) |module| _ = try linkedModule(&program, module.name);
    for (0..3) |_| {
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqualStrings("shared initialized\n", runtime.printedText());
        try t.expectEqual(@as(usize, 1), scene.canvases(&runtime));
        var svg = try runtime.render(machine.getGlobal("scene").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 70 35\"") != null);
    }
}

test "exported infix geometry uses the normal function bytecode and native frame pipeline" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const transforms_source =
        \\import paint.{translate, scale, transformed};precedence transform
        \\ below addition
        \\ above path
        \\ associativity left
        \\end
        \\export transform
        \\fn scaled(p:path,k:float)->path
        \\ return transformed(p,scale(k))
        \\end
        \\mixfix(scaled) _ scaled _ in transform
        \\export scaled
        \\fn shifted(p:path,offset:vec2)->path
        \\ return transformed(p,translate(offset))
        \\end
        \\mixfix(shifted) _ shifted _ in transform
        \\export shifted
    ;
    const source =
        \\import math.abs;import paint.{rgb, circle, bounds, fill, label, picture};import assertions.assert
        \\import "transforms.huak" as transforms
        \\base:=circle((0,0),5)
        \\curve:=base transforms.scaled 2 transforms.shifted (20,30)
        \\ordinary:=transforms.shifted(transforms.scaled(base,2),(20,30))
        \\assert(curve.bounds()==ordinary.bounds())
        \\assert(abs(curve.bounds()[0].x-10pt)<0.000001pt)
        \\assert(abs(curve.bounds()[1].y-40pt)<0.000001pt)
        \\caption:=typ[
        \\Infix Ω $x^2$
        \\]
        \\export pic:=picture(120,80)
        \\default pic
        \\object.append(pic, object.fill(curve, rgb(0.2,0.4,0.7)))
        \\object.append(pic, object.label(caption, (5,65)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{.{ .name = "/native/transforms.huak", .source = transforms_source }}, optimize);
        defer program.deinit();
        var calls: usize = 0;
        for (program.functions[program.entry].code) |instruction| if (instruction.op == .call) {
            const target = program.functions[instruction.a].name;
            if (std.mem.eql(u8, target, "scaled") or std.mem.eql(u8, target, "shifted")) calls += 1;
        };
        try t.expectEqual(@as(usize, 4), calls);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
        const pic = machine.getGlobal("pic").?;
        var svg = try runtime.render(pic, .svg);
        defer svg.deinit();
        var pdf = try runtime.render(pic, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 120 80\"") != null);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/FontFile") != null);
    }
}

test "head and leading mixfix expressions retain ordinary call bytecode and single evaluation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const declarations =
        \\fn negated(x:float)->float;return -x;end
        \\mixfix(negated) negated _ in unary
        \\fn padded(x:int)->int;return x+100;end
        \\mixfix(padded) padded _ in path
        \\fn one(x:int)->int return x+1 end
        \\mixfix(one) one _ in unary
        \\fn combine(left:int,right:int)->int return 10*left+right end
        \\mixfix(combine) combine left _ plus _ in unary
        \\mixfix(combine) _ combine _ in addition
        \\fn clip(first:int,middle:int,last:int)->int return 100*first+10*middle+last end
        \\mixfix(clip) _ clip from _ to _ in addition
        \\events:=[]
        \\fn record(x:int)->int events+=x; return x end
    ;
    const prefix_source = declarations ++ "\n" ++
        \\import assertions.assert
        \\export answer:=negated 2^3+4
        \\assert(answer==-4)
        \\assert(negated negated 3==3)
        \\assert(padded 1+2==103)
        \\assert(one 2==one(2))
        \\assert(combine left 1 plus 2==combine(1,2))
        \\assert(1 combine 2==combine(1,2))
        \\assert(1 clip from 2 to 3==clip(1,2,3))
        \\tracked:=record(4) clip from record(5) to record(6)
        \\assert(tracked==456 and events==[4,5,6])
        \\if true then
        \\    mixfix(combine) combine from _ and_value _ in unary
        \\    assert(combine from 7 and_value 8==78)
        \\    assert(7 combine 8==78)
        \\end
        \\assert(combine left 7 plus 8==78)
    ;
    const ordinary_source = declarations ++ "\n" ++
        \\import assertions.assert
        \\export answer:=negated(2^3)+4
        \\assert(answer==-4)
        \\assert(negated(negated(3))==3)
        \\assert(padded(1+2)==103)
        \\assert(one(2)==one(2))
        \\assert(combine(1,2)==combine(1,2))
        \\assert(combine(1,2)==combine(1,2))
        \\assert(clip(1,2,3)==clip(1,2,3))
        \\tracked:=clip(record(4),record(5),record(6))
        \\assert(tracked==456 and events==[4,5,6])
        \\if true then
        \\    mixfix(combine) combine from _ and_value _ in unary
        \\    assert(combine(7,8)==78)
        \\    assert(combine(7,8)==78)
        \\end
        \\assert(combine(7,8)==78)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var prefix = try compileModulesOptimized(&library, prefix_source, &.{}, optimize);
        defer prefix.deinit();
        var ordinary = try compileModulesOptimized(&library, ordinary_source, &.{}, optimize);
        defer ordinary.deinit();
        try t.expectEqual(ordinary.constants.len, prefix.constants.len);
        for (ordinary.constants, prefix.constants) |expected, actual| try t.expectEqualDeep(expected, actual);
        try t.expectEqual(ordinary.functions.len, prefix.functions.len);
        for (ordinary.functions, prefix.functions) |expected, actual| {
            try t.expectEqualSlices(l.bytecode.Type, expected.parameters, actual.parameters);
            try t.expectEqualSlices(l.bytecode.Type, expected.local_types, actual.local_types);
            try t.expectEqual(expected.code.len, actual.code.len);
            for (expected.code, actual.code) |a, b| {
                try t.expectEqual(a.op, b.op);
                try t.expectEqual(a.a, b.a);
                try t.expectEqual(a.b, b.b);
            }
        }
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &prefix, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
}

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
        try t.expectEqual(huak.core.DisplayList.Color.black, (try filled.scene.getNode(filled.index)).path.style.fill.?);
        var first_children = try scene.owner(first).scene.children(first.object.index);
        _ = first_children.next();
        const inserted = first_children.next().?;
        try t.expect(inserted.eql(scene.object(second)));
        _ = first_children.next();
        const painted = first_children.next().?;
        try t.expectApproxEqAbs(@as(f64, 0.8), (try painted.scene.getNode(painted.index)).path.style.fill.?.b, 1e-12);
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

test "exposed data preserves typed values immutable text snapshots and repeated Program execution" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, label, picture};param initial:int=9007199254740993
        \\count:=initial
        \\scale:=1.25
        \\enabled:=true
        \\title:="Ω #panic(\"not evaluated\")"
        \\font_size:=12pt
        \\ink:=rgb(0.2,0.4,0.6,0.5)
        \\theme:=typ.module[#let style(body) = {
        \\  assert(type(huak)==module)
        \\  assert(type(huak.count)==int)
        \\  assert(type(huak.scale)==float and huak.scale==1.25)
        \\  assert(type(huak.enabled)==bool and huak.enabled)
        \\  assert(type(huak.title)==str and huak.title=="Ω #panic(\"not evaluated\")")
        \\  assert(type(huak.font_size)==length and huak.font_size==12pt)
        \\  assert(type(huak.ink)==color and huak.ink==rgb(20%,40%,60%,50%))
        \\  set text(size:huak.font_size,fill:huak.ink)
        \\  body
        \\}]
        \\typ.show theme.style
        \\first:=typ[Count #huak.count; #huak.title]
        \\again:=typ[Count #huak.count; #huak.title]
        \\count=count+2
        \\changed:=typ[Count #huak.count; #huak.title]
        \\pic:=picture(650,130)
        \\object.append(pic, object.label(first, (10,100)))
        \\object.append(pic, object.label(again, (10,65)))
        \\object.append(pic, object.label(changed, (10,30)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        for ([_]bool{ false, true }) |batched| for ([_][]const u8{ "9007199254740993", "42" }) |initial| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var host = runtime.host();
            var vtable = host.vtable.*;
            if (!batched) vtable.typst_batch = null;
            host.vtable = &vtable;
            var machine = try l.Machine.init(t.allocator, &program, host, .{});
            defer machine.deinit();
            _ = machine.execute(&.{.{ .name = "initial", .value = initial }}) catch |err| {
                if (machine.failure) |failure| std.debug.print("exposure VM: {s}: {s}\n", .{ failure.text(), failure.native_message });
                return err;
            };
            const first = runtime.texts.items[machine.getGlobal("first").?.handle.index];
            const again = runtime.texts.items[machine.getGlobal("again").?.handle.index];
            try t.expectEqualDeep(first.metrics, again.metrics);
            if (batched) try t.expect(first.layout == again.layout);
            var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
            defer svg.deinit();
            try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "#336699") != null);
            var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
            const text = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            const first_number = if (std.mem.eql(u8, initial, "42")) "Count 42" else "Count 9007199254740993";
            const changed_number = if (std.mem.eql(u8, initial, "42")) "Count 44" else "Count 9007199254740995";
            try t.expect(std.mem.indexOf(u8, text, first_number) != null);
            try t.expect(std.mem.indexOf(u8, text, changed_number) != null);
            try t.expect(std.mem.indexOf(u8, text, "Ω #panic(\"not evaluated\")") != null);
        };
    }
}

test "huak data typ.module and typ.show each need a library with the matching capability" {
    const cases = [_]struct { capability: u64, source: []const u8, message: []const u8 }{
        .{ .capability = typst.c.TYPST_CAP_BINDING_MODULES, .source = "x:=1\nread:=typ[#huak.x]", .message = "module bindings" },
        .{ .capability = typst.c.TYPST_CAP_MODULE_HANDLES, .source = "theme:=typ.module[#let style(body) = body]", .message = "module handles" },
        .{ .capability = typst.c.TYPST_CAP_SHOW_VALUES, .source = "theme:=typ.module[#let style(body) = body]\ntyp.show theme.style\nshown:=typ[x]", .message = "show rule values" },
    };
    for (cases) |case| {
        var library = try typst.Library.open(options.library_path);
        defer library.deinit();
        library.capabilities = library.capabilities.? & ~case.capability;
        var program = try compile(&library, case.source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, case.message) != null);
    }
    // Without the member-use query the front end cannot tell what a block reads.
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    library.capabilities = library.capabilities.? & ~@as(u64, typst.c.TYPST_CAP_MEMBER_USES);
    var diagnostic: ?l.compiler.Diagnostic = null;
    try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, "caption:=typ[plain]", "member-uses.huak", .{ .source_parser = .init(&library) }, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), "cannot read the Huak names in a Typst block") != null);
}

test "Typst code that uses huak as a whole value sees exactly the members it reads" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\title:="private"
        \\other:=1
        \\bare:=typ[#assert(type(huak) == module and dictionary(huak) == (:))ok]
        \\imported:=typ[#import huak: *
        \\ok]
        \\passed:=typ[#let count(m) = dictionary(m).len()
        \\#assert(count(huak) == 0)ok]
        \\one:=typ[#assert(dictionary(huak).keys() == ("title",))#huak.title]
        \\theme:=typ.module[#let members = dictionary(huak).len()]
        \\checked:=typ[#assert(huak.theme.members == 0 and dictionary(huak).keys() == ("theme",))ok]
        \\fn local()->text return typ[#assert(dictionary(huak) == (:))ok] end
        \\made:=local()
    ;
    {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
    // Code that does not mention `huak` has none to see.
    var program = try compile(&library, "title:=\"private\"\ncaption:=typ[#eval(\"huak\")]");
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, "unknown variable: huak") != null);
}

test "a typ.module is evaluated when it is made and reused by the modules and blocks that read it" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\size:=30pt
        \\base:=typ.module[#let scale = huak.size
        \\#let fail() = panic("inside base")]
        \\size=1pt
        \\theme:=typ.module[#let style(body) = { set text(size: huak.base.scale); body }
        \\#let fail = huak.base.fail]
        \\plain:=typ[Hello]
        \\shown:=block
        \\    typ.show theme.style
        \\    return typ[Hello]
        \\end
        \\ratio:=shown.width/plain.width
        \\again:=typ[#assert(huak.base.scale == 30pt and huak.theme.style != none)Hello]
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expect(machine.getGlobal("ratio").?.number > 2);

    // An error inside a module that another module read is placed in the
    // text of the module that raised it.
    const failing = source ++ "\nbroken:=typ[#huak.theme.fail()]";
    var failed_program = try compile(&library, failing);
    defer failed_program.deinit();
    var failed_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer failed_runtime.deinit();
    var failed = try l.Machine.init(t.allocator, &failed_program, failed_runtime.host(), .{});
    defer failed.deinit();
    try t.expectError(error.RuntimeFailed, failed.execute(&.{}));
    try t.expect(std.mem.indexOf(u8, failed.failure.?.native_message, "native-test.huak:3:15: panicked with: inside base") != null);
    // A module with an error is reported where it is made.
    var early_program = try compile(&library, "broken:=typ.module[#let x = missing]\nlater:=typ[never]");
    defer early_program.deinit();
    var early_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer early_runtime.deinit();
    var early = try l.Machine.init(t.allocator, &early_program, early_runtime.host(), .{});
    defer early.deinit();
    try t.expectError(error.RuntimeFailed, early.execute(&.{}));
    try t.expect(std.mem.indexOf(u8, early.failure.?.native_message, "native-test.huak:1:29: unknown variable: missing") != null);
}

test "Typst reads respect local shadowing aliases block restoration and module boundaries" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{.{ .name = "/native/reads-library.huak", .source =
        \\export item:="module"
        \\export caption:=typ[#assert(dictionary(huak).keys()==("item",))#huak.item]
    }};
    const source =
        \\import paint.{label, picture};import "reads-library.huak".{item as imported,caption as module_text}
        \\title:="root"
        \\fn make_caption(title:string)->text
        \\    return typ[#assert(huak.title=="local")#assert(huak.imported=="module")#huak.title]
        \\end
        \\local_text:=make_caption("local"); branch_text:=local_text
        \\if true then
        \\    branch:="branch"
        \\    branch_text=typ[#assert(dictionary(huak).keys()==("branch",))#huak.branch]
        \\end
        \\root_text:=typ[#assert(dictionary(huak).keys()==("title","imported"))#huak.title #huak.imported]
        \\pic:=picture(240,160)
        \\object.append(pic, object.label(module_text, (5,135)))
        \\object.append(pic, object.label(local_text, (5,100)))
        \\object.append(pic, object.label(branch_text, (5,65)))
        \\object.append(pic, object.label(root_text, (5,30)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        const text = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        for ([_][]const u8{ "module", "local", "branch", "root module" }) |expected|
            try t.expect(std.mem.indexOf(u8, text, expected) != null);
    }
}

test "Typst reads in template call bodies match ordinary reads" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    // Huak assertions check the ordinary reads; Typst assertions check that the
    // same template parameters and locals reach the request, also in a function.
    const source =
        \\import assertions.assert
        \\expand_block foo(width:length = 2pt)
        \\    a := 1
        \\    ...
        \\end
        \\expand_block bar(gap:length = 1pt)
        \\    c := 3
        \\    foo do
        \\        e := "five"
        \\        ...
        \\    end
        \\end
        \\gap := 9pt
        \\caption := typ[placeholder]
        \\bar do
        \\    assert(gap == 1pt and c == 3 and width == 2pt and a == 1 and e == "five")
        \\    caption = typ[#assert.eq(huak.gap, 1pt)#assert.eq(huak.c, 3)#assert.eq(huak.width, 2pt)#assert.eq(huak.a, 1)#assert.eq(huak.e, "five")#huak.e]
        \\end
        \\fn framed()->text
        \\    result := typ[placeholder]
        \\    bar do
        \\        result = typ[#assert.eq(huak.gap, 1pt)#huak.gap]
        \\    end
        \\    return result
        \\end
        \\framed_caption := framed()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expect(machine.getGlobal("caption") != null);
        try t.expect(machine.getGlobal("framed_caption") != null);
    }
}

test "Typst read batches preserve earlier native errors before later length conversion failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source = "huge:=1e308mm\nfirst:=typ[#missing]\nif true then second:=typ[#huak.huge] end\n";
    for ([_]bool{ false, true }) |optimize| for ([_]bool{ false, true }) |batched| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var host = runtime.host();
        var vtable = host.vtable.*;
        if (!batched) vtable.typst_batch = null;
        host.vtable = &vtable;
        var machine = try l.Machine.init(t.allocator, &program, host, .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, "missing") != null);
        try t.expect(machine.getGlobal("first") == null);
        try t.expect(machine.getGlobal("second") == null);
    };
    for ([_][]const u8{ "[1]", "1deg", "picture(640, 480)" }) |bad| {
        const input = try std.fmt.allocPrint(t.allocator, "import paint.picture;fn read_any(value:any)->text\nreturn typ[#huak.value]\nend\ncaption:=read_any({s})\n", .{bad});
        defer t.allocator.free(input);
        var program = try compile(&library, input);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(machine.getGlobal("caption") == null);
        try t.expect(std.mem.indexOf(u8, machine.failure.?.text(), "Typst code can read") != null);
    }
}

test "directional envelope preserves orientation subpaths and strict zero-line semantics through the VM" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, pen, envelope, rectangle, circle, path, reverse};import geometry.{clipped, region_union};import pen.{pensquare, stroke_outline};shape:=pensquare(4pt)
        \\ink:=rgb(0.2,0.4,0.7)
        \\curve:=circle((40,40),15)
        \\outside:=envelope(curve,shape)
        \\inside:=envelope(reverse(curve),shape)
        \\complete:=stroke_outline(curve,shape)
        \\compound:=region_union(rectangle((0,0),10,10),rectangle((30,0),10,10))
        \\multiple:=envelope(compound,shape)
        \\split:=clipped(path([(-10,0),(10,0),(10,10),(-10,10)]),(0,-1),(5,11))
        \\open_multiple:=envelope(split,shape)
        \\dashed_pen:=pen(ink,1pt,"square","bevel",4,[3pt,2pt],0pt,shape)
        \\plain_pen:=pen(ink,1pt,"square","bevel",4,[],0pt,shape)
        \\line:=path((0,0),(20,0))
        \\dashed:=envelope(line,dashed_pen)
        \\plain:=envelope(line,plain_pen)
        \\singleton:=envelope(path((5,7)),shape)
        \\zero:=envelope(path((5,7),(5,7)),shape)
        \\dot:=stroke_outline(path((5,7),(5,7)),shape)
    ;
    const Inspect = struct {
        fn path(runtime: *l.Runtime, machine: *l.Machine, name: []const u8) huak.core.Path {
            return runtime.path_values.items[machine.getGlobal(name).?.handle.index];
        }
        fn closed(curve: huak.core.Path) usize {
            var count: usize = 0;
            for (curve.segments.items) |segment| if (segment == .close) {
                count += 1;
            };
            return count;
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const outside = Inspect.path(&runtime, &machine, "outside");
        const inside = Inspect.path(&runtime, &machine, "inside");
        try t.expectEqual(@as(usize, 1), Inspect.closed(outside));
        try t.expectEqual(@as(usize, 1), Inspect.closed(inside));
        try t.expect(outside.bounds().?.width() > inside.bounds().?.width());
        try t.expect((Inspect.path(&runtime, &machine, "complete")).segmentCount() > outside.segmentCount());
        try t.expectEqual(@as(usize, 2), Inspect.closed(Inspect.path(&runtime, &machine, "multiple")));
        try t.expectEqual(@as(usize, 2), Inspect.closed(Inspect.path(&runtime, &machine, "open_multiple")));
        // Envelope consumes the geometric pen, not its optional dash pattern.
        try t.expectEqualDeep((Inspect.path(&runtime, &machine, "plain")).segments.items, (Inspect.path(&runtime, &machine, "dashed")).segments.items);
        try t.expect((Inspect.path(&runtime, &machine, "singleton")).bounds().?.width() > 0);
        if ((Inspect.path(&runtime, &machine, "zero")).bounds()) |box| try t.expect(box.width() == 0 and box.height() == 0);
        try t.expect((Inspect.path(&runtime, &machine, "dot")).bounds().?.width() > 0);
    }
}

test "directional envelope rejects elliptical pens with source-located actionable diagnostics" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| for ([_]struct { expression: []const u8, message: []const u8 }{
        .{ .expression = "envelope(curve,pencircle(4pt))", .message = "EllipticalPen" },
        .{ .expression = "envelope(curve,pensquare(4pt),0pt)", .message = "InvalidTolerance" },
    }) |case| {
        const source = try std.fmt.allocPrint(t.allocator, "import paint.{{envelope, path}};import pen.{{pencircle, pensquare}};curve:=path((0,0),(20,0))\nresult:={s}\nafter:=1\n", .{case.expression});
        defer t.allocator.free(source);
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const failure = machine.failure.?;
        try t.expect(std.mem.indexOf(u8, failure.text(), case.message) != null);
        try t.expectEqual(@as(usize, 2), failure.diagnostic.position(source).line);
        if (std.mem.eql(u8, case.message, "EllipticalPen")) try t.expect(std.mem.indexOf(u8, failure.native_message, "polygonal pen") != null);
        try t.expect(machine.getGlobal("result") == null and machine.getGlobal("after") == null);
    };
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

test "exported block templates preserve definition and caller scopes through aliases" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const modules = [_]ModuleSource{
        .{ .name = "/native/builder.huak", .source =
        \\offset:=10
        \\fn put(target:dict,value:int) target["sum"]=target["sum"]+value end
        \\export expand_block collect(target:dict)
        \\    import math.abs
        \\    place:=put.with(target:target)
        \\    mixfix(place) place _ in unary
        \\    ...
        \\    return target["sum"]+extra+offset
        \\end
        },
        .{ .name = "/native/facade.huak", .source = "import \"builder.huak\".collect as gather; export gather" },
    };
    const input =
        \\import "facade.huak".gather
        \\offset:=100
        \\state:={"sum":0}
        \\answer:=gather state do
        \\    extra:=offset
        \\    place int(abs(-3))
        \\    block
        \\        place:=len.with("ab")
        \\        extra=extra+place()
        \\    end
        \\    place(4)
        \\end
        \\forward:=later 2 do value:=3 end
        \\expand_block later(input:int)
        \\    import math.abs
        \\    ...
        \\    return int(abs(-input))+value
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, input, &modules, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(i64, 119), machine.getGlobal("answer").?.int);
        try t.expectEqual(@as(i64, 5), machine.getGlobal("forward").?.int);
    }
}

test "typ.module values carry data snapshots into other modules and nest by scope" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const modules = [_]ModuleSource{.{ .name = "/native/styles.huak", .source =
        \\FACE:="DejaVu Sans Mono"
        \\export fn sized(size:length)->typ.module
        \\    return typ.module[#let style(body) = { set text(font: huak.FACE, size: huak.size); body }]
        \\end
        \\export fn labelled(value:string, theme:typ.module)->text
        \\    typ.show theme.style
        \\    return typ[#huak.value]
        \\end
    }};
    const source =
        \\import assertions.assert
        \\import math.abs
        \\import "styles.huak" as styles
        \\size:=20pt
        \\shout:=typ.module[#let shout(it) = upper(it)]
        \\loud:=typ.module[#let style(body) = { set text(size: huak.size); huak.shout.shout(body) }]
        \\size=6pt
        \\plain:=typ[hello]
        \\big:=styles.labelled("hello", loud)
        \\mono:=styles.sized(11pt)
        \\same:=styles.labelled("hello", mono)
        \\nested:=typ[]
        \\block
        \\    typ.show loud.style
        \\    typ.show mono.style
        \\    nested=typ[hello]
        \\end
        \\upper_mono:=styles.labelled("HELLO", mono)
        \\called:=typ[]
        \\composed:=typ[]
        \\block
        \\    called=typ[#(huak.loud.style)[hello] hello]
        \\    both:=typ.module[#let style(body) = { show: huak.loud.style; strong(body) }]
        \\    block
        \\        typ.show both.style
        \\        composed=typ[hello]
        \\    end
        \\end
        \\struct Styled
        \\    theme: typ.module
        \\end
        \\typed: typ.module := Styled(theme: loud).theme
        \\typed_text:=block
        \\    typ.show typed.style
        \\    return typ[hello]
        \\end
        \\imported:=typ[#import huak: loud;#loud.style[hello]]
        \\assert(abs(typed_text.width-big.width) < 0.001pt, "a typ.module passes through typed fields and declarations")
        \\assert(big.width > 2*plain.width, "a caller's module styles text typeset by another module")
        \\assert(abs(same.width-plain.width) > 0.1pt, "a module keeps the data it read where it was made")
        \\assert(abs(nested.width-upper_mono.width) < 0.001pt, "the inner show's settings win while the outer show still applies")
        \\assert(called.width > big.width and called.width < big.width+plain.width+5pt, "a module member is a Typst function")
        \\assert(composed.width > big.width, "a module applies a module it read")
        \\assert(abs(imported.width-big.width) < 0.001pt, "Typst code imports a module from huak")
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &modules, optimize);
        defer program.deinit();
        for ([_]bool{ false, true }) |batched| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var host = runtime.host();
            var vtable = host.vtable.*;
            if (!batched) vtable.typst_batch = null;
            host.vtable = &vtable;
            var machine = try l.Machine.init(t.allocator, &program, host, .{});
            defer machine.deinit();
            try execute(&machine);
        }
    }

    // Errors name the module's own lines: Typst syntax where the module is
    // made, and evaluation where another module applies its member.
    const failures = [_]struct { source: []const u8, location: []const u8, message: []const u8 }{
        .{ .source = "theme:=typ.module[#let = 1]", .location = "/native/main.huak:1:", .message = "expected pattern" },
        .{ .source = "import \"styles.huak\" as styles\nbroken:=typ.module[#let style(body) = {\n    set text(size: missing_size)\n    body\n}]\nvalue:=styles.labelled(\"x\", broken)", .location = "/native/main.huak:3:20: ", .message = "unknown variable: missing_size" },
    };
    for (failures) |failure| {
        var program = try compileModulesOptimized(&library, failure.source, &modules, true);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const detail = machine.failure.?.native_message;
        try t.expect(std.mem.indexOf(u8, detail, failure.location) != null);
        try t.expect(std.mem.indexOf(u8, detail, failure.message) != null);
    }
}
