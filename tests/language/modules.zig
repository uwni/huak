//! Module linking: function values across imports, wildcard and selected bindings, privacy, shared initialization and exported block templates.
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
const linkedModule = harness.linkedModule;
const compileModules = harness.compileModules;

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
            try t.expect(std.mem.find(u8, svg.bytes(), "viewBox=\"0 0 90 45\"") != null);
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
        try t.expect(std.mem.find(u8, diagnostic.?.text(), case.name) != null);
        if (std.mem.eql(u8, case.name, "unknown_value")) try t.expectEqualStrings("/native/invalid.huak", diagnostic.?.fileName().?);
    };
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
        try t.expect(std.mem.find(u8, svg.bytes(), "viewBox=\"0 0 70 35\"") != null);
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
