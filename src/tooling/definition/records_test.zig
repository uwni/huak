//! Tests of record navigation and record completions.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const testing = @import("testing.zig");
const hover = @import("hover.zig");
const completion = @import("completion.zig");
const Fixture = testing.Fixture;
const describe = hover.describe;
const complete = completion.complete;

test "record navigation follows type annotations constructors aliases fields and named arguments" {
    const input =
        \\struct Widget
        \\    width:int
        \\    options:dict={"key": 1}
        \\end
        \\item:Widget:=Widget(width:3)
        \\alias:=item
        \\value:=alias.width
        \\fn measure(target:Widget)->int
        \\    return target.width
        \\end
        \\answer:=measure(target:alias)
    ;
    const fixture: Fixture = .{ .source = input };
    try fixture.expect("Widget:=Widget", "file:///tmp/definition.huak", input, "Widget");
    try fixture.expect("Widget(width", "file:///tmp/definition.huak", input, "Widget");
    try fixture.expect("width:3", "file:///tmp/definition.huak", input, "width");
    try fixture.expect("width\n", "file:///tmp/definition.huak", input, "width");
    try fixture.expect("target:alias", "file:///tmp/definition.huak", input, "target");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const offset = std.mem.indexOf(u8, input, "width:3").?;
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, offset)).?;
    try std.testing.expectEqualStrings("Widget.width: int", detail);
}

test "record navigation preserves imported reexported type identities and field annotations" {
    const library = "export struct Settings\nsize:int=2\nend\n";
    const facade = "import \"/tmp/settings.huak\".Settings as Options\nexport Options\n";
    const input = "import \"/tmp/facade.huak\" as config\nitem:config.Options:=config.Options(size:3)\nvalue:=item.size\n";
    const fixture: Fixture = .{ .source = input, .files = &.{ .{ .name = "/tmp/settings.huak", .source = library }, .{ .name = "/tmp/facade.huak", .source = facade } } };
    try fixture.expect("Options:=config", "file:///tmp/settings.huak", library, "Settings");
    try fixture.expect("Options(size", "file:///tmp/settings.huak", library, "Settings");
    try fixture.expect("size:3", "file:///tmp/settings.huak", library, "size");
    try fixture.expect("size\n", "file:///tmp/settings.huak", library, "size");
}

test "record completions infer member receivers and offer unsupplied constructor labels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const prefix = "struct Widget\nwidth:int\nheight:int=2\nend\nitem:=Widget(width:1)\n";
    const source = prefix ++ "value:=item.";
    const fields = try complete(&frontend, arena.allocator(), source, "/tmp/completion.huak", source.len);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("width", fields[0].label);
    try std.testing.expectEqualStrings("height", fields[1].label);
    const named = prefix ++ "value:=Widget(width:1,)";
    const arguments = try complete(&frontend, arena.allocator(), named, "/tmp/completion.huak", named.len - 1);
    try std.testing.expectEqual(@as(usize, 1), arguments.len);
    try std.testing.expectEqualStrings("height", arguments[0].label);
    try std.testing.expectEqualStrings("height: ", arguments[0].insertText.?);
    const positional = prefix ++ "value:=Widget(math.abs(1),)";
    const comma = std.mem.lastIndexOfScalar(u8, positional, ',').?;
    for ([_]usize{ comma, comma + 1 }) |offset| {
        const remaining = try complete(&frontend, arena.allocator(), positional, "/tmp/completion.huak", offset);
        try std.testing.expectEqual(@as(usize, 1), remaining.len);
        try std.testing.expectEqualStrings("height", remaining[0].label);
    }
}
