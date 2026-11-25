//! Tests of go-to-definition: locals, aliases, Typst reads, scoped imports, operators, opaque tokens, UTF-16 columns and allocation failure.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const locations = @import("../position.zig");
const standard = @import("huak_std");
const testing = @import("testing.zig");
const hover = @import("hover.zig");
const Fixture = testing.Fixture;
const describe = hover.describe;

test "definitions respect block locals parameters global bindings and UFCS" {
    const source =
        \\global_value:=4
        \\fn increment(value:int)->int
        \\local_value:=value+global_value
        \\if true then local_value=8 end
        \\if true then
        \\    local_value:=9
        \\    print(local_value)
        \\end
        \\for value in [1] do print(value) end
        \\return local_value
        \\end
        \\result:=global_value.increment()
    ;
    const fixture: Fixture = .{ .source = source };
    try fixture.expect("value+", "file:///tmp/definition.huak", source, "value:int");
    try fixture.expect("global_value\n", "file:///tmp/definition.huak", source, "global_value");
    try fixture.expect("local_value\n", "file:///tmp/definition.huak", source, "local_value");
    try fixture.expect("local_value)", "file:///tmp/definition.huak", source, "local_value:=9");
    try fixture.expect("value) end", "file:///tmp/definition.huak", source, "value in");
    try fixture.expect("increment()", "file:///tmp/definition.huak", source, "increment");
}

test "definitions follow selected aliases namespace calls values and reexports" {
    const library = "export fn increment(value:int)->int return value+1 end\nexport amount:=3\n";
    const facade = "import \"/tmp/library.huak\".{increment as bump,amount}\nexport bump,amount\n";
    const source =
        \\import "/tmp/facade.huak".{bump as shifted,amount}
        \\import "/tmp/library.huak" as library
        \\result:=shifted(amount)+library.increment(library.amount)
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{ .{ .name = "/tmp/library.huak", .source = library }, .{ .name = "/tmp/facade.huak", .source = facade } } };
    try fixture.expect("shifted(amount)", "file:///tmp/library.huak", library, "increment");
    try fixture.expect("increment(library", "file:///tmp/library.huak", library, "increment");
    try fixture.expect("amount)", "file:///tmp/library.huak", library, "amount");
    try fixture.expect("amount}", "file:///tmp/library.huak", library, "amount");
    try fixture.expectNone("as shifted");
    try fixture.expectNone("as library");
}

test "huak reads in Typst code navigate to the Huak values they read" {
    const library = "export amount:=3\n";
    const source =
        \\import "/tmp/library.huak".amount as count
        \\title:="Figure"
        \\caption:=typ[#huak.title #huak.count $huak.title$]
        \\fn label(title:string)->text
        \\    return typ[#huak.title]
        \\end
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/library.huak", .source = library }} };
    try fixture.expect("title #huak.count", "file:///tmp/definition.huak", source, "title:=");
    try fixture.expect("count $", "file:///tmp/library.huak", library, "amount");
    try fixture.expect("title$", "file:///tmp/definition.huak", source, "title:=");
    try fixture.expect("title]\nend", "file:///tmp/definition.huak", source, "title:string");
    try fixture.expectNone("#huak.title #huak");
    try fixture.expectNone("huak.title #huak");
}

test "typ.module code stays opaque while typ.show paths navigate through Huak names" {
    const themes = "export theme:=typ.module[#let style(body) = body]\n";
    const source =
        \\import "/tmp/themes.huak" as themes
        \\shout:=typ.module[#let shout(it, size) = text(size: size, upper(it))]
        \\fn styles()->typ.module
        \\    return typ.module[#let style(body) = huak.shout.shout(body, 20pt)]
        \\end
        \\big:=styles()
        \\fn caption()->text
        \\    typ.show big.style
        \\    typ.show themes.theme.style
        \\    return typ[body]
        \\end
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/themes.huak", .source = themes }} };
    try fixture.expect("shout.shout(body", "file:///tmp/definition.huak", source, "shout:=");
    try fixture.expect("big.style", "file:///tmp/definition.huak", source, "big:=");
    try fixture.expect("theme.style\n    return", "file:///tmp/themes.huak", themes, "theme");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const namespace = (try fixture.lookup(arena.allocator(), "themes.theme.style")).?;
    try std.testing.expectEqualStrings("/tmp/themes.huak", namespace.path);
    try std.testing.expectEqualDeep(locations.at(themes, 0), namespace.range.start);
    try std.testing.expectEqualDeep(locations.at(themes, 0), namespace.range.end);
    try fixture.expectNone("style\n    typ.show themes");
    try fixture.expectNone("style\n    return");
    try fixture.expectNone("show big");
    try fixture.expectNone("module\n    return");
    try fixture.expectNone("it, size");
    try fixture.expectNone("size: size");
    try fixture.expectNone("shout(body");
}

test "definitions use scoped callable imports and restore outer callable after block" {
    const library = "export fn increment(value:int)->int return value end\n";
    const source =
        \\fn count(value:int)->int return value end
        \\if true then
        \\import "/tmp/library.huak".increment as count
        \\inside:=count(1)
        \\end
        \\outside:=count(2)
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/library.huak", .source = library }} };
    try fixture.expect("count(1)", "file:///tmp/library.huak", library, "increment");
    try fixture.expect("count(2)", "file:///tmp/definition.huak", source, "count");
}

test "definitions classify operators and mixfix labels without treating arguments as labels" {
    const source =
        \\precedence transform above addition;associativity left end
        \\fn shifted(left:int,right:int)->int return left+right end
        \\mixfix(shifted) _ shifted _ in transform
        \\fn twice(value:int)->int return 2*value end
        \\mixfix(twice) twice _ in unary
        \\fn combine(left:int,right:int)->int return left+right end
        \\mixfix(combine) sum from _ to _ in unary
        \\amount:=3
        \\a:=amount shifted 4
        \\b:=twice amount
        \\c:=sum from amount to 5
    ;
    const fixture: Fixture = .{ .source = source };
    try fixture.expect("shifted 4", "file:///tmp/definition.huak", source, "shifted");
    try fixture.expect("twice amount", "file:///tmp/definition.huak", source, "twice");
    try fixture.expect("sum from amount", "file:///tmp/definition.huak", source, "combine");
    try fixture.expect("from amount", "file:///tmp/definition.huak", source, "combine");
    try fixture.expect("to 5", "file:///tmp/definition.huak", source, "combine");
    try fixture.expect("amount to", "file:///tmp/definition.huak", source, "amount");
    try fixture.expect("transform\n", "file:///tmp/definition.huak", source, "transform");
}

test "definitions keep comments literals native fields and builtins opaque" {
    const source = "fn target()->int return 1 end\n// target\nvalue:=\"target\"\npoint:=(1,2)\nresult:=point.x+sin(0)\n";
    const fixture: Fixture = .{ .source = source };
    try fixture.expectNone("target\n");
    try fixture.expectNone("target\"");
    try fixture.expectNone("x+sin");
    try fixture.expectNone("sin(0)");
    try (Fixture{ .source = "fn broken(\nx=broken()" }).expectNone("broken()");
}

test "standard definitions expose source functions while native functions remain opaque" {
    const source = "import assertions.assert\nassert(true)\n";
    const fixture: Fixture = .{ .source = source };
    try fixture.expect("assert(true)", "huak-stdlib:/std/assertions.huak", standard.source("std/assertions.huak").?, "assert");
    const native: Fixture = .{ .source = "import paint.*\np:=circle((0,0),2)\n" };
    try native.expectNone("circle((");
}

test "definitions preserve UTF16 columns and percent encode filenames" {
    const source = "label:=\"🙂\";value:=1\nresult:=value\n";
    const fixture: Fixture = .{ .name = "/tmp/figure space.huak", .source = source };
    try fixture.expect("value\n", "file:///tmp/figure%20space.huak", source, "value");
}

test "an imported data value navigates to its file" {
    const fixture: Fixture = .{
        .source = "import \"/tmp/points.csv\" as rows\nfirst:=rows[0]",
        .files = &.{.{ .name = "/tmp/points.csv", .source = "1,2" }},
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const target = (try fixture.lookup(arena.allocator(), "rows[0]")).?;
    try std.testing.expectEqualStrings("/tmp/points.csv", target.path);
    try std.testing.expectEqual(locations.at("1,2", 0), target.range.start);
}

test "definition request arenas release allocations on every allocation failure" {
    const fixture: Fixture = .{ .source = "fn target(value:int)->int return value end\nresult:=target(4)\n" };
    const Check = struct {
        fn run(allocator: std.mem.Allocator, input: *const Fixture) !void {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            try std.testing.expect(try input.lookup(arena.allocator(), "target(4)") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{&fixture});
}

test "qualified operators share exported identities while namespace tokens navigate to module" {
    const library = "export fn shifted(left:int,right:int)->int return left+right end\nmixfix(shifted) _ shifted _ in addition\nexport fn twice(value:int)->int return value*2 end\nmixfix(twice) twice _ in unary\n";
    const source = "import \"/tmp/library.huak\" as lib\nx:=1 lib.shifted 2\ny:=lib.twice 3\nmixfix(lib.twice) double _ in unary\nz:=double 3\n";
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/library.huak", .source = library }} };
    try fixture.expect("shifted 2", "file:///tmp/library.huak", library, "shifted");
    try fixture.expect("twice 3", "file:///tmp/library.huak", library, "twice");
    try fixture.expect("twice) double", "file:///tmp/library.huak", library, "twice");
    try fixture.expect("double 3", "file:///tmp/library.huak", library, "twice");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = (try fixture.lookup(arena.allocator(), "lib.twice")).?;
    try std.testing.expectEqualStrings("/tmp/library.huak", result.path);
    try std.testing.expectEqualDeep(locations.Position{ .line = 0, .character = 0 }, result.range.start);
}

test "nested drawing modules preserve imported mixfix and infix navigation" {
    const input =
        \\import std
        \\import std.paint.circle as disk
        \\curve:=std.paint.circle with center (0,0) radius 2
        \\other:=circle with center (2,3) radius 4
        \\placed:=content std.paint.at (5,6)
    ;
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("center (0,0)");
    try fixture.expectNone("center (2,3)");
    try fixture.expect("at (5,6)", "huak-stdlib:/std/paint.huak", standard.source("std/paint.huak").?, "at(content");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "center (0,0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn geometry.circle("));
    const template = "export expand_block drawing(target:int)\nplace:=len.with(\"abc\")\nmixfix(place) place _ in unary\n...\nreturn target\nend\n";
    const caller = "import \"/tmp/commands.huak\".drawing as paint\nanswer:=paint 3 do\nplace()\nend\n";
    const expanded: Fixture = .{ .source = caller, .files = &.{.{ .name = "/tmp/commands.huak", .source = template }} };
    try expanded.expect("paint 3", "file:///tmp/commands.huak", template, "drawing");
    try expanded.expect("place()", "file:///tmp/commands.huak", template, "place:=");
    const symbolic: Fixture = .{ .source = "fn subtract(a:int,b:int)->int return a-b end\nmixfix(subtract) _ + _ in addition\nx:=8+3\n" };
    try symbolic.expect("+ _", "file:///tmp/definition.huak", symbolic.source, "subtract(a");
    try symbolic.expect("+3", "file:///tmp/definition.huak", symbolic.source, "subtract(a");
    const bound: Fixture = .{ .source = "fn command(value:int)->int return value end\nanswer:=block\ncommand:=command.with(value:1)\nreturn command()\nend\n" };
    try bound.expect("command.with", "file:///tmp/definition.huak", bound.source, "command(value");
    try bound.expect("command()", "file:///tmp/definition.huak", bound.source, "command:=");
}
