//! typ.module: evaluation and reuse, data snapshots across modules, and the library capabilities it needs.
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
        try t.expect(std.mem.find(u8, machine.failure.?.native_message, case.message) != null);
    }
    // Without the member-use query the front end cannot tell what a block reads.
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    library.capabilities = library.capabilities.? & ~@as(u64, typst.c.TYPST_CAP_MEMBER_USES);
    var diagnostic: ?l.compiler.Diagnostic = null;
    try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, "caption:=typ[plain]", "member-uses.huak", .{ .source_parser = .init(&library) }, &diagnostic));
    try t.expect(std.mem.find(u8, diagnostic.?.text(), "cannot read the Huak names in a Typst block") != null);
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
    try t.expect(std.mem.find(u8, failed.failure.?.native_message, "native-test.huak:3:15: panicked with: inside base") != null);
    // A module with an error is reported where it is made.
    var early_program = try compile(&library, "broken:=typ.module[#let x = missing]\nlater:=typ[never]");
    defer early_program.deinit();
    var early_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer early_runtime.deinit();
    var early = try l.Machine.init(t.allocator, &early_program, early_runtime.host(), .{});
    defer early.deinit();
    try t.expectError(error.RuntimeFailed, early.execute(&.{}));
    try t.expect(std.mem.find(u8, early.failure.?.native_message, "native-test.huak:1:29: unknown variable: missing") != null);
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
            if (!batched) vtable.typstBatch = null;
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
        try t.expect(std.mem.find(u8, detail, failure.location) != null);
        try t.expect(std.mem.find(u8, detail, failure.message) != null);
    }
}
