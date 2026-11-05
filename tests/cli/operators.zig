const h = @import("harness.zig");
const unrelated = @embedFile("../fixtures/cli/operators/unrelated.huak");
pub fn run(ctx: *h.Harness) !void {
    const basic = try ctx.fixture("operators/basics");
    _ = try ctx.command("check", basic, &.{}, true);
    _ = try ctx.command("run", basic, &.{}, true);
    try h.contains((try ctx.command("disassemble", basic, &.{}, true)).stdout, "call");
    const associations = try ctx.fixture("operators/associations");
    _ = try ctx.command("run", associations, &.{}, true);
    const order = try ctx.fixture("operators/order");
    try h.output(try ctx.command("run", order, &.{}, true), "1\n2\n3\n123\n");
    const recursive = try ctx.fixture("operators/recursive");
    _ = try ctx.command("run", recursive, &.{}, true);
    const parenthesized = try ctx.script("operators/unrelated_parenthesized", "import assertions.assert\n" ++ unrelated ++ "assert((1 firstop 2) secondop 3==1203)\nassert(1 firstop (2 secondop 3)==213)\n");
    _ = try ctx.command("run", parenthesized, &.{}, true);
    const invalid = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "unrelated", .source = unrelated ++ "value:=1 firstop 2 secondop 3\n" },
        .{ .name = "none_chain", .source = "precedence single\nbelow addition\nabove path\nassociativity none\nend\nmixfix _ op _ in single\nfn op(a:int,b:int)->int;return a-b;end\nvalue:=20 op 5 op 2\n" },
        .{ .name = "default_none_chain", .source = "precedence single\nbelow addition\nabove path\nend\nmixfix _ op _ in single\nfn op(a:int,b:int)->int;return a-b;end\nvalue:=20 op 5 op 2\n" },
        .{ .name = "cycle", .source = "precedence first\nabove second\nend\nprecedence second\nabove first\nend\n" },
        .{ .name = "unknown_group", .source = "precedence first\nabove missing\nend\n" },
        .{ .name = "duplicate_group", .source = "precedence repeated\nend\nprecedence repeated\nend\n" },
        .{ .name = "duplicate_binding", .source = "fn op(a:int,b:int)->int;return a+b;end\nmixfix _ op _ in addition\nmixfix _ op _ in addition\n" },
        .{ .name = "unknown_binding", .source = "mixfix _ missing _ in addition\n" },
        .{ .name = "value_binding", .source = "value:=1\nmixfix _ value _ in addition\n" },
        .{ .name = "arity_one", .source = "fn one(a:int)->int;return a;end\nmixfix _ one _ in addition\n" },
        .{ .name = "arity_three", .source = "fn many(a:int,b:int,c:int)->int;return a+b+c;end\nmixfix _ many _ in addition\n" },
        .{ .name = "builtin_arity", .source = "import math.sqrt;mixfix _ sqrt _ in addition\n" },
        .{ .name = "duplicate_association", .source = "precedence repeated\nassociativity left\nassociativity right\nend\n" },
        .{ .name = "bad_association", .source = "precedence bad\nassociativity diagonal\nend\n" },
        .{ .name = "nested_group", .source = "if false then\nprecedence local\nend\nend\n" },
        .{ .name = "escaped_binding", .source = "fn op(a:int,b:int)->int;return a+b;end\nif false then\nmixfix _ op _ in addition\nend\nvalue:=1 op 2\n" },
        .{ .name = "wrong_type", .source = "fn op(a:int,b:int)->int;return a+b;end\nmixfix _ op _ in addition\nvalue:=1 op \"wrong\"\n" },
        .{ .name = "dead_wrong_type", .source = "fn op(a:int,b:int)->int;return a+b;end\nmixfix _ op _ in addition\nif false then\nvalue:=1 op \"wrong\"\nend\n" },
        .{ .name = "reserved_precedence", .source = "precedence=1\n" },
        .{ .name = "reserved_mixfix", .source = "mixfix=1\n" },
    };
    for (invalid) |case| {
        const path = try ctx.script(try ctx.fmt("operators/invalid_{s}", .{case.name}), case.source);
        try h.output(try ctx.command("check", path, &.{}, false), "");
    }
    inline for ([_][]const u8{ "operators/lib/common", "operators/lib/scaling", "operators/lib/shifting" }) |name| {
        _ = try ctx.fixture(name);
    }
    const shared = try ctx.fixture("operators/shared");
    _ = try ctx.command("run", shared, &.{}, true);
    const early = try ctx.fixture("operators/early_infix");
    const early_result = try ctx.command("run", early, &.{}, false);
    try h.either(early_result.stderr, "import", "initializ");
    _ = try ctx.fixture("operators/lib/wrapper");
    const wrapper = try ctx.fixture("operators/wrapped");
    _ = try ctx.command("run", wrapper, &.{}, true);
    _ = try ctx.fixture("operators/lib/disjoint");
    const bridge = try ctx.fixture("operators/foreign_bridge");
    const bridge_result = try ctx.command("check", bridge, &.{}, false);
    try h.either(bridge_result.stderr, "group", "precedence");
    const private_source = "precedence privategroup\nbelow addition\nabove path\nassociativity left\nend\nfn combine(a:int,b:int)->int;return a*10+b;end\nmixfix _ combine _ in privategroup\nexport combine\n";
    _ = try ctx.script("operators/lib/first", private_source);
    _ = try ctx.script("operators/lib/second", private_source);
    const private = try ctx.fixture("operators/private_groups");
    _ = try ctx.command("run", private, &.{}, true);
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "private_operator", .source = "import \"lib/scaling.huak\" as ops\nvalue:=1 ops.privateop 2\n" },
        .{ .name = "no_infix_role", .source = "import \"lib/scaling.huak\" as ops\nvalue:=1 ops.normal 2\n" },
        .{ .name = "private_group", .source = "import \"lib/first.huak\" as ops\nfn local(a:int,b:int)->int;return a+b;end\nmixfix _ local _ in ops.privategroup\n" },
        .{ .name = "mixed_private_groups", .source = "import \"lib/first.huak\" as first\nimport \"lib/second.huak\" as second\nvalue:=1 first.combine 2 second.combine 3\n" },
    }) |case| {
        const path = try ctx.script(try ctx.fmt("operators/{s}", .{case.name}), case.source);
        try h.output(try ctx.command("check", path, &.{}, false), "");
    }
    const group = try ctx.fixture("operators/group_export");
    _ = try ctx.command("check", group, &.{}, true);
    const exported = try ctx.command("run", group, &.{ "--output", "transforms=group.svg" }, false);
    try h.contains(exported.stderr, "output 'transforms' is not defined");
    try ctx.absent("group.svg");
    _ = try ctx.fixture("operators/lib/geometry");
    const drawing = try ctx.fixture("operators/drawing");
    _ = try ctx.command("run", drawing, &.{ "--output", "infix.svg", "--output", "pic=infix.pdf" }, true);
    try (try ctx.svg("infix.svg")).viewBox("0 0 120 80");
    try h.contains(try ctx.pdfText("infix.pdf", false), "Infix Ω");
}
