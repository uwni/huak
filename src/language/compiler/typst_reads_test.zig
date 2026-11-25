//! Tests of Typst reads: captured names, rejected values, whole-huak use, templates, imports and native quantities.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const ModuleGraph = @import("../ModuleGraph.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const testing = @import("testing.zig");
const typstCompile = testing.typstCompile;
const expectTypstRequests = testing.expectTypstRequests;
const expectTypstFailure = testing.expectTypstFailure;
const typstOptions = testing.typstOptions;
const compile = compilation.compile;

test "Typst reads capture the names the code uses once each from their scopes" {
    const input =
        \\outer:=1
        \\first:=typ[#huak.outer #huak.outer]
        \\if true then
        \\    inside:="inside"
        \\    middle:=typ[#huak.outer #huak.inside]
        \\else
        \\    other:=2
        \\    alternate:=typ[#huak.other]
        \\end
        \\none:=typ[#other.outer]
        \\fn make_caption(outer:int)->text
        \\    local_value:="local"
        \\    return typ[#huak.local_value $huak.outer$]
        \\end
    ;
    var program = try typstCompile(std.testing.allocator, input, false);
    defer program.deinit();
    try expectTypstRequests(&program, program.functions[0], &.{
        .{ .names = &.{"outer"}, .loads = &.{.load_global} },
        .{ .names = &.{ "outer", "inside" }, .loads = &.{ .load_global, .load_local } },
        .{ .names = &.{"other"}, .loads = &.{.load_local} },
        .{ .names = &.{} },
    });
    try expectTypstRequests(&program, program.functions[1], &.{.{ .names = &.{ "local_value", "outer" }, .loads = &.{ .load_local, .load_local } }});
}

test "Typst reads reject unknown names functions and values Typst cannot receive" {
    try expectTypstFailure("value:=typ[#huak.missing]", "Typst code reads huak.missing, which names no readable Huak value here");
    try expectTypstFailure("fn function()->int return 1 end\nvalue:=typ[#huak.function]", "Typst code reads huak.function, which names no readable Huak value here");
    try expectTypstFailure("value:=typ[#huak.pi]", "Typst code reads huak.pi, which names no readable Huak value here");
    try expectTypstFailure("items:=[1]\nvalue:=typ[#huak.items]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.items has type list");
    // A forward declaration is checked with its inferred type.
    try expectTypstFailure("if false then value:=typ[#huak.later] end\nlater:=[1]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.later has type list");
    try expectTypstFailure("value:=picture(640, 480)\ncaption:=typ[#huak.value]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.value has type picture");
    try expectTypstFailure("value:=1deg\ncaption:=typ[#huak.value]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.value has type angle");
    // Code that binds `huak` itself may read its own members, so only
    // readable values Typst can receive are captured.
    var rebound = try typstCompile(std.testing.allocator, "items:=[1]\ncount:=2\nvalue:=typ[#let huak = (items: 1); #huak.items #huak.unknown #huak.count]", false);
    defer rebound.deinit();
    try expectTypstRequests(&rebound, rebound.functions[0], &.{.{ .names = &.{"count"} }});
}

test "Typst instructions record whether the code uses huak as a whole value" {
    const input =
        \\count:=2
        \\bare:=typ[#repr(huak)]
        \\both:=typ[#repr(huak) #huak.count]
        \\member:=typ[#huak.count]
        \\plain:=typ[text]
        \\lib:=typ.module[#let all = huak]
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try typstCompile(std.testing.allocator, input, optimize);
        defer program.deinit();
        try expectTypstRequests(&program, program.functions[0], &.{
            .{ .names = &.{}, .whole = true },
            .{ .names = &.{"count"}, .whole = true },
            .{ .names = &.{"count"} },
            .{ .names = &.{} },
            .{ .op = .typst_module, .names = &.{}, .whole = true, .module = "lib" },
        });
    }
}

test "Typst reads in template call bodies resolve like ordinary reads" {
    // The body sees template parameters and locals, including the parameter
    // that shadows a caller global and names forwarded by a nested insertion.
    const forwarded =
        \\expand_block foo(width:length = 2pt)
        \\    a := 1
        \\    ...
        \\end
        \\expand_block bar(gap:length = 1pt)
        \\    c := 3
        \\    foo do
        \\        e := 5
        \\        ...
        \\    end
        \\end
        \\gap := 9pt
        \\bar do
        \\    caption := typ[#huak.gap #huak.c #huak.width #huak.a #huak.e]
        \\end
    ;
    var program = try typstCompile(std.testing.allocator, forwarded, false);
    defer program.deinit();
    const locals: []const bc.Op = &.{ .load_local, .load_local, .load_local, .load_local, .load_local };
    try expectTypstRequests(&program, program.functions[0], &.{.{ .names = &.{ "gap", "c", "width", "a", "e" }, .loads = locals }});
    var optimized = try typstCompile(std.testing.allocator, forwarded, true);
    optimized.deinit();
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (!std.mem.eql(u8, path, "frames")) return error.UnknownModule;
            return .{ .name = "frames.huak", .source = "export expand_block frame(gap:length = 1pt)\n    inner := 3\n    ...\nend\nexport expand_block broken()\n    value := typ[#huak.missing]\n    ...\nend\n" };
        }
    };
    var marker: u8 = 0;
    var options = typstOptions(false);
    options.import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } };
    var diagnostic: ?Diagnostic = null;
    var imported = try compile(std.testing.allocator, "import \"frames\".frame\ngap := 9pt\nfn caption()->text\n    result := typ[]\n    frame do\n        result = typ[#huak.gap #huak.inner]\n    end\n    return result\nend", "frames-root.huak", options, &diagnostic);
    defer imported.deinit();
    var function: ?bc.Function = null;
    for (imported.functions) |candidate| if (std.mem.eql(u8, candidate.name, "caption")) {
        function = candidate;
    };
    try expectTypstRequests(&imported, function.?, &.{ .{ .names = &.{} }, .{ .names = &.{ "gap", "inner" }, .loads = &.{ .load_local, .load_local } } });

    const Failure = struct { input: []const u8, message: []const u8, file: []const u8 = "typst-template.huak", line: usize, column: usize };
    const failures = [_]Failure{
        // An invoked template checks the reads in its own body, and an
        // imported template reports them in its defining module.
        .{ .input = "expand_block frame()\n    value := typ[#huak.missing]\n    ...\nend\nframe do\nend", .message = "Typst code reads huak.missing, which names no readable Huak value here", .line = 2, .column = 24 },
        .{ .input = "import \"frames\".broken\nbroken do\nend", .message = "Typst code reads huak.missing, which names no readable Huak value here", .file = "frames.huak", .line = 6, .column = 24 },
        .{ .input = "expand_block frame()\n    items := [1]\n    ...\nend\nframe do\n    caption := typ[#huak.items]\nend", .message = "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.items has type list", .line = 6, .column = 26 },
        .{ .input = "expand_block frame()\n    ...\nend\nframe do\n    if false then caption := typ[#huak.later] end\n    later := [1]\nend", .message = "local variable used before its declaration is complete", .line = 5, .column = 40 },
        .{ .input = "expand_block frame()\n    ...\nend\nframe do\n    caption := typ[#huak.missing]\nend", .message = "Typst code reads huak.missing, which names no readable Huak value here", .line = 5, .column = 26 },
    };
    for (failures) |failure| {
        var detail: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, failure.input, "typst-template.huak", options, &detail));
        try std.testing.expectEqualStrings(failure.message, detail.?.text());
        try std.testing.expectEqualStrings(failure.file, detail.?.fileName().?);
        const position = detail.?.position("");
        try std.testing.expectEqual(failure.line, position.line);
        try std.testing.expectEqual(failure.column, position.column);
    }
}

test "Typst reads preserve imported aliases initialization checks and module isolation" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (!std.mem.eql(u8, path, "library")) return error.UnknownModule;
            return .{ .name = "library.huak", .source = "export title:=\"title\"\nlabel:=typ[#huak.title]\n" };
        }
    };
    var marker: u8 = 0;
    var options = typstOptions(false);
    options.import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } };
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "import \"library\".title as caption\na:=typ[#huak.caption]", "typst-root.huak", options, &diagnostic);
    defer program.deinit();
    const root = program.functions[program.entry];
    var root_found = false;
    for (root.code, 0..) |instruction, position| if (instruction.op == .typst) {
        root_found = true;
        try std.testing.expectEqual(@as(u32, 1), instruction.b);
        try std.testing.expectEqual(bc.Op.check_module, root.code[position - 2].op);
        try std.testing.expectEqualStrings("caption", program.constants[root.code[position - 3].a].string);
    };
    try std.testing.expect(root_found);
    var bare = try compile(std.testing.allocator, "import \"library\" as library\na:=typ[]", "unread-root.huak", options, &diagnostic);
    defer bare.deinit();
    var seen: [2]bool = @splat(false);
    for (bare.functions) |function| for (function.code) |instruction| if (instruction.op == .typst) {
        try std.testing.expectEqual(@as(u32, if (function.module == 0) 0 else 1), instruction.b);
        seen[function.module] = true;
    };
    try std.testing.expect(seen[0] and seen[1]);
}

fn typstReadAllocationExercise(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |optimize| {
        var program = try typstCompile(allocator, "count:=1\nfn make_caption(count:int)->text\ntyp.show style.style\nreturn typ[#huak.count]\nend\nstyle:=typ.module[#huak.count]\nfirst:=typ[#huak.count]\nif true then local:=2;second:=typ[#huak.local #huak.count] end", optimize);
        defer program.deinit();
    }
}

test "Typst read lowering releases every failed allocation" {
    try typstReadAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), typstReadAllocationExercise, .{});
}

test "Typst reads include native lengths colors and runtime checked quantities" {
    var program = try typstCompile(std.testing.allocator, "import color.rgb\ndistance:=2cm\nink:=rgb(0.1,0.2,0.3)\nflexible:quantity:=3mm\ncaption:=typ[#huak.distance #huak.ink #huak.flexible]", false);
    defer program.deinit();
    try expectTypstRequests(&program, program.functions[program.entry], &.{.{ .names = &.{ "distance", "ink", "flexible" } }});
}
