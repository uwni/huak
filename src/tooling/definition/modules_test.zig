//! Tests of nested namespaces, standard modules and data shadowing across modules.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const locations = @import("../position.zig");
const testing = @import("testing.zig");
const hover = @import("hover.zig");
const completion = @import("completion.zig");
const Fixture = testing.Fixture;
const describe = hover.describe;
const complete = completion.complete;

test "nested exported namespaces retain definitions types and module identities" {
    const library = "export struct Widget\nwidth:int\nend\nexport fn increment(value:int)->int return value+1 end\n";
    const facade = "import \"/tmp/nested-library.huak\" as tools\nexport tools\n";
    const input =
        \\import "/tmp/nested-facade.huak" as facade
        \\import "/tmp/nested-facade.huak".tools.{increment as bump,Widget}
        \\item:facade.tools.Widget:=facade.tools.Widget(width:3)
        \\result:=facade.tools.increment(bump(item.width))
    ;
    const fixture: Fixture = .{ .source = input, .files = &.{ .{ .name = "/tmp/nested-library.huak", .source = library }, .{ .name = "/tmp/nested-facade.huak", .source = facade } } };
    try fixture.expect("increment(bump", "file:///tmp/nested-library.huak", library, "increment");
    try fixture.expect("bump(item", "file:///tmp/nested-library.huak", library, "increment");
    try fixture.expect("Widget:=facade", "file:///tmp/nested-library.huak", library, "Widget");
    try fixture.expect("Widget(width", "file:///tmp/nested-library.huak", library, "Widget");
    try fixture.expect("width:3", "file:///tmp/nested-library.huak", library, "width");
    try fixture.expect("width))", "file:///tmp/nested-library.huak", library, "width");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .overlay = .{ .ptr = @constCast(&fixture), .vtable = &.{ .resolve = Fixture.resolve } } };
    const module_hover = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.find(u8, input, "tools.Widget:=").?)).?;
    try std.testing.expectEqualStrings("module /tmp/nested-library.huak", module_hover);
    const module_location = (try fixture.lookup(arena.allocator(), "tools.Widget:=")).?;
    try std.testing.expectEqualStrings("/tmp/nested-library.huak", module_location.path);
    try std.testing.expectEqualDeep(locations.Position{ .line = 0, .character = 0 }, module_location.range.start);
    const unfinished = "import \"/tmp/nested-facade.huak\" as facade\nvalue:=facade.tools.";
    const members = try complete(&frontend, arena.allocator(), unfinished, fixture.name, unfinished.len);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    for (members) |member| try std.testing.expect(std.mem.eql(u8, member.label, "Widget") or std.mem.eql(u8, member.label, "increment"));
}

test "standard root completes modules and nested native members without fake definitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const root = "import std\nvalue:=std.";
    const modules_ = try complete(&frontend, a, root, "/tmp/standard-root.huak", root.len);
    var has_weave = false;
    var has_regions = false;
    for (modules_) |module| {
        has_weave = has_weave or std.mem.eql(u8, module.label, "weave");
        has_regions = has_regions or std.mem.eql(u8, module.label, "regions");
        try std.testing.expectEqual(@as(u8, 9), module.kind);
        try std.testing.expect(!std.mem.eql(u8, module.label, "assert") and !std.mem.eql(u8, module.label, "circle"));
        try std.testing.expect(std.mem.startsWith(u8, module.detail, "module "));
    }
    try std.testing.expect(has_weave and has_regions);
    const input = "import std\nimport std.math.{cos as cosine,PI as pi}\nvalue:=std.math.sin(cosine(pi))\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("sin(cosine");
    try fixture.expectNone("cosine(pi)");
    try fixture.expectNone("pi))");
    const native_hover = (try describe(&frontend, a, input, fixture.name, std.mem.find(u8, input, "sin(cosine").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, native_hover, "fn math.sin("));
    const alias_hover = (try describe(&frontend, a, input, fixture.name, std.mem.find(u8, input, "cosine(pi)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, alias_hover, "fn math.cos("));
    const constant_hover = (try describe(&frontend, a, input, fixture.name, std.mem.find(u8, input, "pi))").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, constant_hover, "math.PI: number"));
    const math = "import std\nvalue:=std.math.";
    const members = try complete(&frontend, a, math, fixture.name, math.len);
    var has_sin = false;
    var has_pi = false;
    for (members) |member| {
        has_sin = has_sin or std.mem.eql(u8, member.label, "sin");
        has_pi = has_pi or std.mem.eql(u8, member.label, "PI");
        try std.testing.expect(!std.mem.eql(u8, member.label, "circle"));
    }
    try std.testing.expect(has_sin and has_pi);
    const named = "import std\nvalue:=std.geometry.circle(center:(0,0),)";
    const labels = try complete(&frontend, a, named, fixture.name, named.len - 1);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("radius", labels[0].label);
}

test "tooling follows ordinary data shadowing and imports become visible at their declaration" {
    const input =
        \\fn count(value:int)->int return value end
        \\fn probe(count:int)->int
        \\    return count(1)
        \\end
        \\before:=disk((0,0),1)
        \\import geometry.circle as disk
        \\after:=disk((0,0),1)
    ;
    const fixture: Fixture = .{ .source = input };
    try fixture.expect("count(1)", "file:///tmp/definition.huak", input, "count:int");
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const before = std.mem.find(u8, input, "disk((").?;
    try std.testing.expect(try describe(&frontend, arena.allocator(), input, fixture.name, before) == null);
    const after = std.mem.findLast(u8, input, "disk((").?;
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, after)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn geometry.circle("));
    const early = try complete(&frontend, arena.allocator(), input, fixture.name, std.mem.find(u8, input, "before:=").?);
    for (early) |item| try std.testing.expect(!std.mem.eql(u8, item.label, "disk"));
    const late = try complete(&frontend, arena.allocator(), input, fixture.name, std.mem.find(u8, input, "after:=").?);
    var found = false;
    for (late) |item| found = found or std.mem.eql(u8, item.label, "disk");
    try std.testing.expect(found);
}
