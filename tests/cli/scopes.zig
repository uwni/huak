const h = @import("harness.zig");

const invalid = [_][]const u8{
    "fn local() import \"first.huak\".value end; print(value)",
    "if true then import \"first.huak\" as inside end; print(inside.value)",
    "if true then import \"first.huak\".value as branch else print(branch) end",
    "if true then import \"first.huak\".value; import \"second.huak\".value end",
    "if false then import \"first.huak\".hidden end",
    "if true then export hidden:=1 end",
    "fn identity(x:int)->int return x end; if true then mixfix(identity) identity _ in unary end; print(identity 1)",
    "outer:=1; if true then import \"second.huak\".value as outer; outer=2 end",
    "missing=1",
    "value:=1; value:=2",
    "value:int=1",
    "if true then value:=1 end; print(value)",
    "for value in [1] do end; print(value)",
    "import drawing.drawing;drawing picture() do value:=1 end; print(value)",
    "for i in 0:2 do value:=value+1 end",
};
pub const process_count = 5 + invalid.len;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("scopes/first",
        \\print("first initialized")
        \\export value:=11
        \\export fn mark(x:int)->int return x+1 end
        \\mixfix(mark) mark _ in unary
        \\fn hidden()->int return 0 end
    );
    _ = try ctx.script("scopes/second",
        \\import paint.{label, picture};print("second initialized")
        \\export value:=22
        \\export fn mark(x:int)->int return x+10 end
        \\mixfix(mark) mark _ in unary
        \\export fn make()->picture
        \\    p:=picture(20mm,10mm)
        \\    object.append(p, object.label(typ[Scoped label], (1mm,6mm)))
        \\    return p
        \\end
    );
    _ = try ctx.script("scopes/unused", "print(\"unused initialized\"); export unused:=1");
    const path = try ctx.script("scopes/main",
        \\import drawing.drawing
        \\import paint.{picture, append};import assertions.assert
        \\import "first.huak".*
        \\import "first.huak" as config
        \\fn nested()->int
        \\    import "second.huak".{mark,value}
        \\    assert(mark 1==11)
        \\    if true then
        \\        import "first.huak".mark
        \\        assert(mark 1==2)
        \\    end
        \\    assert(mark 1==11)
        \\    return value
        \\end
        \\assert(nested()==22); assert(mark 1==2); assert(value==11)
        \\if true then import "second.huak" as config; assert(config.value==22) end
        \\assert(config.value==11)
        \\if false then import "unused.huak".* end
        \\for i in 0:2 do import "second.huak".value; assert(value==22) end
        \\assert(value==11)
        \\total:=0; item:=99
        \\for item in [1,2,3] do
        \\    local:int:=item
        \\    if true then local:=10; total=total+local end
        \\    total=total+local
        \\end
        \\assert(total==36 and item==99)
        \\fn update()->int
        \\    total=total+1
        \\    if true then total:=7; total=total+1; assert(total==8) end
        \\    return total
        \\end
        \\assert(update()==37 and total==37)
        \\n:=0
        \\while n<2 do import "second.huak".value; assert(value==22); n=n+1 end
        \\assert(value==11)
        \\fn identity(x:int)->int return x end
        \\result:=0; if true then mixfix(identity) identity _ in unary; result=identity 7 end
        \\assert(result==7)
        \\export plate :=picture(40mm,20mm)
        \\default plate
        \\drawing plate do
        \\    import "second.huak".make
        \\    +make()
        \\end
    );
    _ = try ctx.command("check", path, &.{}, true);
    try h.output(try ctx.command("run", path, &.{ "--output", "scopes.svg", "--output", "plate=scopes.pdf" }, true), "first initialized\nsecond initialized\n");
    _ = try ctx.svg("scopes.svg");
    try h.contains(try ctx.pdfText("scopes.pdf", false), "Scoped label");
    try h.contains((try ctx.command("disassemble", path, &.{}, true)).stdout, "import_module");

    const not_called = try ctx.script("scopes/not-called", "import paint.picture;fn lazy() import \"unused.huak\".* end; default picture(2,3)");
    try h.output(try ctx.command("run", not_called, &.{ "--output", "scopes-lazy.svg" }, true), "");
    const early = try ctx.script("scopes/early", "fn bad()->int return value; import \"first.huak\".value end; print(bad())");
    try h.contains((try ctx.command("run", early, &.{}, false)).stderr, "unknown name 'value'");
    for (invalid, 0..) |source, index| {
        const script = try ctx.script(try ctx.fmt("scopes/invalid-{d}", .{index}), source);
        try h.output(try ctx.command("check", script, &.{}, false), "");
    }
}
