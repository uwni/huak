//! Tests of typ.show and typ.module.
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

test "typ.show declarations add no runtime work without a typ block" {
    var original = try typstCompile(std.testing.allocator, "theme:=typ.module[]", false);
    defer original.deinit();
    var declared = try typstCompile(std.testing.allocator, "theme:=typ.module[]\ntyp.show theme.style", false);
    defer declared.deinit();
    try std.testing.expectEqual(original.constants.len, declared.constants.len);
    try std.testing.expectEqual(original.functions[0].code.len, declared.functions[0].code.len);
    for (original.functions[0].code, declared.functions[0].code) |left, right| {
        try std.testing.expectEqual(left.op, right.op);
        try std.testing.expectEqual(left.a, right.a);
        try std.testing.expectEqual(left.b, right.b);
    }
    var future = try typstCompile(std.testing.allocator, "if false then typ.show future.style; future:=typ.module[] end", true);
    defer future.deinit();
    for (future.functions[0].code) |instruction| try std.testing.expect(instruction.op != .load_global and instruction.op != .load_local);
}

test "typ.show paths apply outermost first while typ.module captures reads only" {
    const input =
        \\size:=2pt
        \\outer:=typ.module[#let style(b) = b]
        \\inner:=typ.module[#let style(b) = text(huak.size, b)]
        \\typ.show outer.style
        \\fn caption()->text
        \\    typ.show inner.style
        \\    typ.show outer.style
        \\    return typ[#huak.size]
        \\end
        \\plain:=typ[]
    ;
    var program = try typstCompile(std.testing.allocator, input, false);
    defer program.deinit();
    try expectTypstRequests(&program, program.functions[0], &.{
        .{ .op = .typst_module, .names = &.{}, .module = "outer" },
        .{ .op = .typst_module, .names = &.{"size"}, .globals = &.{"size"}, .module = "inner" },
        .{ .names = &.{".style"}, .globals = &.{"outer"} },
    });
    try expectTypstRequests(&program, program.functions[1], &.{.{ .names = &.{ "size", ".style", ".style" }, .globals = &.{ "size", "outer", "inner" } }});
    // A module's instruction spans exactly its code.
    for (program.functions[0].code) |instruction| if (instruction.op == .typst_module) {
        try std.testing.expect(std.mem.startsWith(u8, program.source_text[instruction.span.start..instruction.span.end], "[#let style(b) = "));
        try std.testing.expect(program.source_text[instruction.span.end - 1] == ']');
    };
}

test "typ.module reads only the names its code uses and never itself" {
    const input =
        \\size:=2pt
        \\mark:=typ.module[#let mark(body) = text(huak.size, body)]
        \\shout:=typ.module[#let shout(body) = huak.mark.mark(upper(body))]
        \\fn make()->typ.module return typ.module[] end
    ;
    var program = try typstCompile(std.testing.allocator, input, false);
    defer program.deinit();
    // A module is named after the name it is assigned to.
    try expectTypstRequests(&program, program.functions[0], &.{
        .{ .op = .typst_module, .names = &.{"size"}, .module = "mark" },
        .{ .op = .typst_module, .names = &.{"mark"}, .module = "shout" },
    });
    try expectTypstRequests(&program, program.functions[1], &.{.{ .op = .typst_module, .names = &.{}, .module = "module" }});
    try expectTypstFailure("theme:=typ.module[#huak.theme]", "Typst code reads huak.theme, which names no readable Huak value here");
    try expectTypstFailure("fn make()->typ.module\n    theme:=typ.module[#huak.theme]\n    return theme\nend", "Typst code reads huak.theme, which names no readable Huak value here");
}

test "typ.show and typ.module reject values Typst cannot receive" {
    try expectTypstFailure("count:=1\ntyp.show count.style\nvalue:=typ[]", "typ.show needs a typ.module value; 'count' has type int");
    try expectTypstFailure("count:=1\nblock\n    typ.show count.style\nend", "typ.show needs a typ.module value; 'count' has type int");
    try expectTypstFailure("typ.show missing.style", "typ.show needs a readable typ.module value, found 'missing'");
    try expectTypstFailure("theme:=typ.module[]\ntyp.show theme", "typ.show needs a member of a typ.module value, such as theme.style");
    try expectTypstFailure("items:=[1]\nrule:=typ.module[#huak.items]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.items has type list");
    try expectTypstFailure("fn make()->text return typ.module[] end", "expected text, found typ.module");
}

test "typ.show paths reach typ.module exports through import namespaces" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "themes")) return .{ .name = "themes.huak", .source = "export theme:=typ.module[#let style(b) = b]\nexport count:=1\nexport fn helper()->int return 1 end\n" };
            return .{ .name = "outer.huak", .source = "import \"themes\" as themes\nexport themes\n" };
        }
    };
    var marker: u8 = 0;
    var options = typstOptions(false);
    options.import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } };
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "import \"themes\" as themes\nimport \"outer\" as outer\ntyp.show themes.theme.style\ntyp.show outer.themes.theme.page.style\na:=typ[]", "show-root.huak", options, &diagnostic);
    defer program.deinit();
    const root = program.functions[program.entry];
    var found = false;
    for (root.code, 0..) |instruction, position| if (instruction.op == .typst) {
        found = true;
        try std.testing.expectEqual(@as(u32, 2), instruction.b);
        // Each show value is checked for its initialized module, then loaded.
        try std.testing.expectEqual(bc.Op.load_global, root.code[position - 1].op);
        try std.testing.expectEqualStrings("themes.huak::theme", program.global_names[root.code[position - 1].a]);
        var members: [2][]const u8 = undefined;
        var count: usize = 0;
        for (root.code[0..position]) |earlier| if (earlier.op == .constant and program.constants[earlier.a] == .string and program.constants[earlier.a].string.len > 0 and program.constants[earlier.a].string[0] == '.') {
            members[count] = program.constants[earlier.a].string;
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, 2), count);
        try std.testing.expectEqualStrings(".style", members[0]);
        try std.testing.expectEqualStrings(".page.style", members[1]);
    };
    try std.testing.expect(found);
    const failures = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "import \"themes\" as themes\ntyp.show themes.style", .message = "module 'themes.huak' does not export 'style'" },
        .{ .input = "import \"themes\" as themes\ntyp.show themes.theme", .message = "typ.show needs a member of the typ.module value, such as theme.style" },
        .{ .input = "import \"themes\" as themes\ntyp.show themes.count.style", .message = "typ.show needs a typ.module value; 'count' has type int" },
        .{ .input = "import \"themes\" as themes\ntyp.show themes.helper.style", .message = "typ.show needs a readable typ.module value, found 'helper'" },
    };
    for (failures) |failure| {
        var detail: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, failure.input, "show-root.huak", options, &detail));
        try std.testing.expectEqualStrings(failure.message, detail.?.text());
    }
}
