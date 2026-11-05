const h = @import("harness.zig");

const invalid = [_]struct { source: []const u8, message: []const u8 }{
    .{ .source = "assert(true)", .message = "unknown function 'assert'" },
    .{ .source = "import assertions.assert; assert()", .message = "expects 1..2 arguments" },
    .{ .source = "import assertions.assert; assert(true,\"a\",\"b\")", .message = "expects 1..2 arguments" },
    .{ .source = "import assertions.assert; assert(1)", .message = "expected boolean" },
    .{ .source = "import assertions.assert; assert(true,1)", .message = "expected string" },
    .{ .source = "panic()", .message = "expects 1 arguments" },
    .{ .source = "panic(1)", .message = "expected string" },
};
pub const process_count = 9 + invalid.len;

pub fn run(ctx: *h.Harness) !void {
    const source = try ctx.script("assertions/main",
        \\import assertions.assert
        \\import assertions as library
        \\import assertions.assert as ensure
        \\export assert,panic
        \\assert(true); assert(true,"unused"); library.assert(true)
        \\ensure(true); true.assert("UFCS")
        \\events:=[]
        \\fn condition()->bool events+=1; return true end
        \\fn message()->string events+=2; return "unused" end
        \\assert(condition(),message()); assert(events==[1,2])
        \\mixfix assert _ in logical_or
        \\assert true
        \\mixfix _ ensure _ in comparison
        \\true ensure "infix"
        \\if true then
        \\    mixfix assert that _ message _ in logical_or
        \\    assert that true message "mixfix"
        \\end
        \\assert true
        \\print("assertions passed")
    );
    _ = try ctx.command("check", source, &.{}, true);
    try h.output(try ctx.command("run", source, &.{}, true), "assertions passed\n");
    const assembly = try ctx.command("disassemble", source, &.{}, true);
    try h.contains(assembly.stdout, "export assert (function");
    try h.contains(assembly.stdout, "export panic (builtin panic)");

    const direct = try ctx.script("assertions/direct", "panic(\"direct panic Ω\")");
    try h.contains((try ctx.command("run", direct, &.{}, false)).stderr, "direct panic Ω");
    const missing = try ctx.script("assertions/default", "import assertions.assert; assert(false)");
    try h.contains((try ctx.command("run", missing, &.{}, false)).stderr, "assertion failed");
    const explicit = try ctx.script("assertions/nested",
        \\import assertions.assert
        \\fn outer() assert(false,"assertion detail Ω") end
        \\outer()
    );
    const failure = try ctx.command("run", explicit, &.{}, false);
    try h.contains(failure.stderr, "assertion detail Ω");
    try h.contains(failure.stderr, "assertions.huak");
    try h.contains(failure.stderr, "outer");
    const early = try ctx.script("assertions/early",
        \\fn argument()->bool print("must not run"); return true end
        \\assert(argument())
        \\import assertions.assert
    );
    const early_failure = try ctx.command("run", early, &.{}, false);
    try h.output(early_failure, "");
    try h.contains(early_failure.stderr, "unknown function 'assert'");

    const ordered = try ctx.script("assertions/ordered",
        \\import paint.picture;import assertions.assert
        \\fn make(index:int)->picture
        \\    assert(index!=2,"ordered assertion failure")
        \\    return picture(10,10)
        \\end
        \\export first:=make(1)
        \\export second:=make(2)
        \\export third:=make(3)
    );
    const serial = try ctx.command("run", ordered, &.{ "-j1", "--output", "first=assertions-first.svg" }, false);
    const parallel = try ctx.command("run", ordered, &.{ "-j4", "--output", "first=assertions-first.svg" }, false);
    try h.contains(parallel.stderr, "ordered assertion failure");
    try @import("std").testing.expectEqualStrings(serial.stderr, parallel.stderr);
    try ctx.absent("assertions-first.svg");
    for (invalid, 0..) |item, index| {
        const script = try ctx.script(try ctx.fmt("assertions/invalid-{d}", .{index}), item.source);
        try h.contains((try ctx.command("check", script, &.{}, false)).stderr, item.message);
    }
}
