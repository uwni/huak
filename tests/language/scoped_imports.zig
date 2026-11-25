//! Lexical imports: restoring namespaces, members and callable roles, privacy, declaration order and shadowing.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const scene = @import("../support/scene.zig");
const ModuleSource = @import("../support/modules.zig").ModuleSource;
const ModuleResolver = @import("../support/modules.zig").ModuleResolver;
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const execute = harness.execute;

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
