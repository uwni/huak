const h = @import("harness.zig");

pub const process_count = 7;

pub fn run(ctx: *h.Harness) !void {
    const folded = try ctx.script("optimization/folded",
        \\A:=2*3
        \\B:=A+4
        \\result:=0; if B>8 then result=B*2 else panic("DEAD_PROPAGATION_BRANCH") end
        \\print(result)
    );
    const assembly = try ctx.command("disassemble", folded, &.{}, true);
    try h.excludes(assembly.stdout, "load_global");
    try h.excludes(assembly.stdout, "multiply");
    try h.excludes(assembly.stdout, "greater");
    try h.excludes(assembly.stdout, "jump_if_false");
    try h.output(try ctx.command("run", folded, &.{}, true), "20\n");

    const varying = try ctx.script("optimization/parameter",
        \\param choose:bool=false
        \\result:=0; if choose then result=2 else result=3 end
        \\print(result)
    );
    try h.output(try ctx.command("run", varying, &.{ "--param", "choose=false" }, true), "3\n");
    try h.output(try ctx.command("run", varying, &.{ "--param", "choose=true" }, true), "2\n");

    const overflow = try ctx.script("optimization/overflow", "A:=9223372036854775807\nresult:=A+1");
    try h.contains((try ctx.command("run", overflow, &.{}, false)).stderr, "integer overflow");
    const division = try ctx.script("optimization/division", "A:=10\nresult:=A/0");
    try h.contains((try ctx.command("run", division, &.{}, false)).stderr, "division by zero");
    const uninitialized = try ctx.script("optimization/uninitialized", "param choose:bool=false\nif not choose then print(MAYBE) end\nMAYBE:=7\nprint(MAYBE)");
    try h.contains((try ctx.command("run", uninitialized, &.{}, false)).stderr, "used before initialization");
}
