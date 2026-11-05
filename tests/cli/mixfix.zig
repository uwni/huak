const h = @import("harness.zig");

const invalid = [_][]const u8{
    "import geometry.joined; mixfix _ joined _ in path",
    "import paint.joined; a:=path((0,0),(1,1)); b:=path((1,1),(2,2)); result:=a joined b",
    "import paint.joined; a:=path((0,0),(1,1)); b:=path((1,1),(2,2)); result:=a joined & b",
    "import paint.joined as glue; a:=path((0,0),(1,1)); b:=path((1,1),(2,2)); result:=a glue b",
    "import paint.*; curve:=circle with radius 2mm center (0mm,0mm)",
    "import paint.*; curve:=circle with center (0mm,0mm)",
    "fn f(a:int,b:int)->int return a+b end; mixfix(f) f with _ _ in unary",
    "fn f(a:int)->int return a end; mixfix(f) f with _ ending in unary",
    "fn f(a:int)->int return a end; mixfix(f) f with _ mm _ in unary",
    "fn f(a:int)->int return a end; mixfix(f) f with _ other _ in unary",
    "mixfix(absent) absent with _ in unary",
    "fn f(a:int)->int return a end; if true then mixfix(f) f with _ in unary end; f with 1",
    "import \"library.huak\" as lib; mixfix(lib.private) hidden _ in unary",
    "import \"library.huak\" as lib; mixfix(lib.combine) wrong _ in unary",
    "import \"library.huak\" as lib; mixfix(lib.combine.with(1)) wrong _ in unary",
    "import \"library.huak\" as lib; mixfix(lib.combine) triple _ and_value _ and_value _ in unary; value:=combine(1,2,3)",
};
pub const process_count = 8 + invalid.len;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("mixfix/symbols",
        \\precedence sum above path; below multiplication; associativity left end
        \\export fn difference(a:int,b:int)->int return a-b end
        \\mixfix(difference) _ + _ in sum
    );
    _ = try ctx.script("mixfix/symbol_bridge", "import \"symbols.huak\".difference as subtract; export subtract");
    _ = try ctx.script("mixfix/library",
        \\import paint.circle;precedence wording above addition; below multiplication; associativity left end
        \\export fn combine(a:int,b:int,c:int)->int return 100*a+10*b+c end
        \\mixfix(combine) combine with first _ second _ third _ in wording
        \\fn private(a:int)->int return a end
        \\mixfix(private) private with _ in unary
        \\export circle
        \\mixfix(circle) centered center _ radius _ in unary
    );
    _ = try ctx.script("mixfix/pairs",
        \\precedence chaining below addition; above path; associativity left end
        \\export fn one(value:int)->int return value+1 end
        \\mixfix(one) one _ in unary
        \\export fn combine(left:int,right:int)->int return 10*left+right end
        \\mixfix(combine) pair_digits left _ plus _ in unary
        \\mixfix(combine) _ paired _ in chaining
        \\export fn clip(first:int,middle:int,last:int)->int return 100*first+10*middle+last end
        \\mixfix(clip) _ clip from _ to _ in chaining
        \\export fn as(left:int,right:int)->int return 10*left+right end
        \\mixfix(as) digits _ as _ in unary
    );
    _ = try ctx.script("mixfix/reexport",
        \\import "library.huak".combine as join
        \\export join
    );
    _ = try ctx.script("mixfix/templates",
        \\import "reexport.huak" as inner
        \\export inner
        \\precedence local above addition end
        \\export expand_block digits()
        \\    mixfix(inner.join) decimal _ tens _ units _ in local
        \\    ...
        \\end
    );
    const path = try ctx.script("mixfix/main",
        \\import paint.{draw, append};import paint.*;import assertions.assert
        \\import paint as drawing_library
        \\import paint.circle as disk
        \\import "library.huak".circle as plain_circle
        \\import "pairs.huak".{one as increment,combine as join_pair,clip as splice}
        \\import "reexport.huak".join as combine
        \\export disk
        \\import "templates.huak" as templates
        \\block
        \\    mixfix(templates.inner.join) _ digits _ then_value _ in addition
        \\    mixfix(math.sqrt) root_of _ in unary
        \\    assert((1 digits 2 then_value 3) == 123)
        \\    assert(root_of 49 == 7)
        \\    inner := 42
        \\    templates.digits() do
        \\        decimal := inner
        \\        assert((decimal 1 tens 2 units 3) + (decimal) == 165)
        \\    end
        \\end
        \\assert(10+3*2==16)
        \\block
        \\    import "symbol_bridge.huak".subtract as difference
        \\    assert(10+3*2==4 and difference(10,6)==4)
        \\    block
        \\        import math.sqrt
        \\        mixfix(sqrt) + _ in unary
        \\        assert(+9==3 and 10+3==7)
        \\    end
        \\end
        \\assert(+9==9 and 10+3==13)
        \\block
        \\    import "pairs.huak".as as decimal
        \\    import math.sqrt as root
        \\    mixfix(root) root as value _ in unary
        \\    as := 4
        \\    assert((digits as as 2) == decimal(4, 2))
        \\    assert((root as value as) == 2)
        \\end
        \\assert(combine with first 1 second 2 third 3==123)
        \\assert(combine(1,2,3)==123)
        \\assert(one 2==increment(2))
        \\assert(pair_digits left 1 plus 2==join_pair(1,2))
        \\assert(1 paired 2==join_pair(1,2))
        \\assert(1 clip from 2 to 3==splice(1,2,3))
        \\assert(len(centered center (0mm,0mm) radius 1mm)==len(plain_circle((0mm,0mm),1mm)))
        \\events:=[]
        \\fn record(x:int)->int events+=x; return x end
        \\result:=combine with first record(1) second record(2) third record(3)
        \\assert(result==123 and events==[1,2,3])
        \\events=[]
        \\result=record(4) clip from record(5) to record(6)
        \\assert(result==456 and events==[4,5,6])
        \\if true then
        \\    mixfix(combine) combine first _ then_value _ lastly _ in unary
        \\    assert(combine first 4 then_value 5 lastly 6==456)
        \\end
        \\assert(combine with first 1 second 2 third 3==123)
        \\if true then
        \\    mixfix(join_pair) join_pair left _ right _ in unary
        \\    assert(join_pair left 7 right 8==join_pair(7,8))
        \\    assert(7 paired 8==join_pair(7,8))
        \\end
        \\assert(pair_digits left 7 plus 8==join_pair(7,8))
        \\blue:=rgb with red 0.1 green 0.3 blue 0.8
        \\export plate :=picture with width 80mm height 50mm
        \\default plate
        \\drawing plate do
        \\    +draw (circle with center (20mm,20mm) radius 10mm)
        \\    +draw (drawing_library.circle with center (55mm,20mm) radius 10mm)
        \\    +rectangle with origin (5mm,5mm) width 70mm height 4mm filled blue
        \\    +draw ((5mm,10mm)--(75mm,10mm)) with (pen with color blue width 0.4mm)
        \\    +typ[Mixfix Ω] at (25mm,40mm)
        \\end
        \\assert(len(disk((0mm,0mm),1mm))==len(drawing_library.circle((0mm,0mm),1mm)))
    );
    _ = try ctx.command("check", path, &.{}, true);
    _ = try ctx.command("run", path, &.{ "-j4", "--output", "mixfix.svg", "--output", "plate=mixfix.pdf" }, true);
    _ = try ctx.svg("mixfix.svg");
    try h.contains(try ctx.pdfText("mixfix.pdf", false), "Mixfix Ω");
    const assembly = try ctx.command("disassemble", path, &.{}, true);
    try h.contains(assembly.stdout, "mixfix(disk) circle with center _ radius _");
    try h.contains(assembly.stdout, "builtin circle");
    try h.contains((try ctx.command("run", path, &.{ "--output", "disk=invalid.svg" }, false)).stderr, "output 'disk' is not defined");
    try ctx.absent("invalid.svg");

    const early = try ctx.script("mixfix/early",
        \\fn record()->int print("must not run"); return 1 end
        \\value:=combine with first record() second 2 third 3
        \\import "reexport.huak".join
    );
    const early_error = try ctx.command("run", early, &.{}, false);
    try h.output(early_error, "");
    try h.contains(early_error.stderr, "no matching mixfix declaration");
    const private = try ctx.script("mixfix/private", "import \"library.huak\".private");
    try h.contains((try ctx.command("check", private, &.{}, false)).stderr, "does not export");
    const example = try ctx.script("mixfix/defaults",
        \\import paint.joined as glue
        \\import assertions.assert
        \\left := (0,0)--(1,1)
        \\right := (1,1)--(2,0)
        \\assert(len(left & right) == len(glue(left, right)))
        \\import paint.*
        \\export p :=picture with width 50mm height 30mm
        \\default p
        \\curve:=(2mm,2mm)~~(25mm,20mm)~~(48mm,2mm)
        \\drawing p do +fill tapered along curve width 1mm end
    );
    _ = try ctx.command("check", example, &.{}, true);
    _ = try ctx.command("run", example, &.{ "--output", "mixfix-defaults.svg" }, true);
    _ = try ctx.svg("mixfix-defaults.svg");
    for (invalid, 0..) |source, index| {
        const script = try ctx.script(try ctx.fmt("mixfix/invalid-{d}", .{index}), source);
        _ = try ctx.command("check", script, &.{}, false);
    }
}
