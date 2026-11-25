//! Tests of native namespaces in hover and completion: default math, shadowing, explicit imports, owned members and constructors.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const builtins = @import("../../language/builtin.zig");
const testing = @import("testing.zig");
const hover = @import("hover.zig");
const completion = @import("completion.zig");
const Fixture = testing.Fixture;
const describe = hover.describe;
const complete = completion.complete;

test "default math completion and hover use native metadata without source navigation" {
    const input = "fn sin(value:int)->int return value end\nvalue:=math.sin(0)\nangle:=math.PI\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("sin(0)");
    try fixture.expectNone("PI\n");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const function = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "sin(0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, function, "fn math.sin("));
    const constant = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "PI\n").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, constant, "math.PI: number = 3.14"));
    const unfinished = "value:=math.";
    const members = try complete(&frontend, arena.allocator(), unfinished, fixture.name, unfinished.len);
    var sin = false;
    var pi = false;
    for (members) |item| {
        sin = sin or std.mem.eql(u8, item.label, "sin");
        pi = pi or std.mem.eql(u8, item.label, "PI");
        try std.testing.expect(!std.mem.eql(u8, item.label, "print") and !std.mem.eql(u8, item.label, "picture"));
    }
    try std.testing.expect(sin and pi);
    const ordinary = try complete(&frontend, arena.allocator(), "value:=1", fixture.name, 0);
    var namespace = false;
    for (ordinary) |item| {
        namespace = namespace or std.mem.eql(u8, item.label, "math");
        try std.testing.expect(!std.mem.eql(u8, item.label, "sin"));
    }
    try std.testing.expect(namespace);
}

test "data and imported namespace bindings shadow default math tooling" {
    const input = "struct Settings\nPI:int\nend\nmath:=Settings(PI:2)\nvalue:=math.PI\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expect("PI\n", "file:///tmp/definition.huak", input, "PI");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.lastIndexOf(u8, input, "PI\n").?)).?;
    try std.testing.expectEqualStrings("Settings.PI: int", detail);
    const unfinished = "struct Settings\nPI:int\nend\nmath:=Settings(PI:2)\nvalue:=math.";
    const members = try complete(&frontend, arena.allocator(), unfinished, fixture.name, unfinished.len);
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("PI", members[0].label);
    const library = "export fn sin(value:int)->int return value end\n";
    const namespaced: Fixture = .{ .source = "import \"/tmp/custom-math.huak\" as math\nvalue:=math.sin(2)\n", .files = &.{.{ .name = "/tmp/custom-math.huak", .source = library }} };
    try namespaced.expect("sin(2)", "file:///tmp/custom-math.huak", library, "sin");
}

test "explicit math imports retain native hover and never invent a source document" {
    const input = "import math.sin as sine\nimport math.PI as pi\nimport math as native\nvalue:=sine(0)\nangle:=pi\nother:=native.cos(0)\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("sine(0)");
    try fixture.expectNone("pi\n");
    try fixture.expectNone("cos(0)");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const function = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "sine(0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, function, "fn math.sin("));
    const constant = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.lastIndexOf(u8, input, "pi\n").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, constant, "math.PI: number"));
    const cosine = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "cos(0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, cosine, "fn math.cos("));
}

test "default native domains expose only their owned members and canonical hover" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    for (std.enums.values(builtins.Namespace)) |namespace| {
        const input = try std.fmt.allocPrint(a, "value:={s}.", .{namespace.name()});
        const members = try complete(&frontend, a, input, "/tmp/domains.huak", input.len);
        var expected: usize = 0;
        for (builtins.signatures) |signature| if (signature.namespace == namespace) {
            expected += 1;
            var found = false;
            for (members) |member| if (std.mem.eql(u8, member.label, signature.name)) {
                found = true;
                const prefix = try std.fmt.allocPrint(a, "fn {s}.{s}(", .{ namespace.name(), signature.name });
                try std.testing.expect(std.mem.startsWith(u8, member.detail, prefix));
            };
            try std.testing.expect(found);
        };
        expected += builtins.constantNames(namespace).len;
        try std.testing.expectEqual(expected, members.len);
        const namespace_source = try std.fmt.allocPrint(a, "value:={s}", .{namespace.name()});
        const namespace_hover = (try describe(&frontend, a, namespace_source, "/tmp/domains.huak", "value:=".len)).?;
        try std.testing.expect(std.mem.startsWith(u8, namespace_hover, namespace.name()));
    }
}

test "native domain data shadowing and imported aliases preserve their distinct targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    for (std.enums.values(builtins.Namespace)) |namespace| {
        const prefix = try std.fmt.allocPrint(a, "struct Settings value:int end\n{s}:=Settings(value:2)\nanswer:={s}.", .{ namespace.name(), namespace.name() });
        const members = try complete(&frontend, a, prefix, "/tmp/shadow.huak", prefix.len);
        try std.testing.expectEqual(@as(usize, 1), members.len);
        try std.testing.expectEqualStrings("value", members[0].label);
        const input = try std.fmt.allocPrint(a, "{s}value\n", .{prefix});
        const detail = (try describe(&frontend, a, input, "/tmp/shadow.huak", prefix.len)).?;
        try std.testing.expectEqualStrings("Settings.value: int", detail);
    }
    const facade = "import geometry.circle as disk\nexport disk\n";
    const input = "import \"/tmp/domain-facade.huak\".disk as ring\nvalue:=ring((0,0),1)\n";
    const fixture: Fixture = .{ .source = input, .files = &.{.{ .name = "/tmp/domain-facade.huak", .source = facade }} };
    try fixture.expectNone("ring((");
    frontend.overlay = .{ .ptr = @constCast(&fixture), .vtable = &.{ .resolve = Fixture.resolve } };
    const detail = (try describe(&frontend, a, input, fixture.name, std.mem.indexOf(u8, input, "ring((").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn geometry.circle("));
}

test "primary native constructors remain callable through their normal namespace binding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const input = "import std.pen\nnib:=pen(color.rgb(0,0,0))\n";
    const detail = (try describe(&frontend, arena.allocator(), input, "/tmp/constructors.huak", std.mem.indexOf(u8, input, "pen(color").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn pen.pen("));
    const members = try complete(&frontend, arena.allocator(), input, "/tmp/constructors.huak", std.mem.indexOf(u8, input, "nib:=").?);
    var found = false;
    for (members) |member| if (std.mem.eql(u8, member.label, "pen")) {
        try std.testing.expectEqual(@as(u8, 4), member.kind);
        try std.testing.expect(std.mem.startsWith(u8, member.detail, "fn pen("));
        found = true;
    };
    try std.testing.expect(found);
    const alias = "import std.math as pen\nnib:=pen(1)\n";
    const invalid = (try describe(&frontend, arena.allocator(), alias, "/tmp/constructors.huak", std.mem.indexOf(u8, alias, "pen(1)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, invalid, "math —"));
}
