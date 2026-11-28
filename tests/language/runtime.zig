//! The runtime and program lifecycle: reuse across executions, input copies, bounded formatting and outputs.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

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
    const text = try l.Runtime.formatting.formatValue(t.allocator, .{ .vec2 = .{ .x = 1e308, .y = 1e-308 } });
    defer t.allocator.free(text);
    try t.expect(text.len > 0);
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
    try t.expect(std.mem.find(u8, old_svg.bytes(), "viewBox=\"0 0 90 45\"") != null);
    try t.expect(std.mem.find(u8, new_svg.bytes(), "viewBox=\"0 0 120 70\"") != null);
    try t.expect(std.mem.find(u8, pdf.bytes(), "/ToUnicode") != null);
    try t.expectEqual(@as(usize, 1), runtime.frames.items.len);
}
