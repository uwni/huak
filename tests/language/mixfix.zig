//! User operators: function aliases with precedence groups, infix geometry, head and leading mixfix, and the formatter round trip of prefix binding.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const ModuleSource = @import("../support/modules.zig").ModuleSource;
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;
const compileModulesOptimized = harness.compileModulesOptimized;
const linkedModule = harness.linkedModule;

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
    try t.expect(std.mem.find(u8, formatted, "prefixed := twice (2)+3") != null);
    try t.expect(std.mem.find(u8, formatted, "ordinary := twice(2)+3") != null);
    try t.expect(std.mem.find(u8, formatted, "literal := \"x=1,y=2\"") != null);
    try t.expect(std.mem.find(u8, formatted, "typ[Formatting a=b,c]") != null);
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
            const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{});
            defer t.allocator.free(text);
            try t.expect(std.mem.find(u8, text, "Formatting a=b,c") != null);
        }
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
        try t.expect(std.mem.find(u8, svg.bytes(), "viewBox=\"0 0 120 80\"") != null);
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
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
        try t.expect(std.mem.find(u8, svg.bytes(), "viewBox=\"0 0 120 80\"") != null);
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
        try t.expect(std.mem.find(u8, pdf.bytes(), "/ToUnicode") != null);
        try t.expect(std.mem.find(u8, pdf.bytes(), "/FontFile") != null);
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
