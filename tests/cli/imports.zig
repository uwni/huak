//! Import bindings use the same native function and export paths as namespaces.
const std = @import("std");
const h = @import("harness.zig");
const t = std.testing;

const invalid = [_][]const u8{
    "import \"library.huak\".hidden",
    "import \"library.huak\".{make, missing}",
    "import \"library.huak\".{add as same, twice as same}",
    "import \"library.huak\".{}",
    "import \"library.huak\".make\ndefault library.make(10mm)",
    "import paint.picture;import \"library.huak\".*\nfn make(width:length)->picture return picture(width,10mm) end",
    "fn one()->int return 1 end\nexport one, one",
    "fn one()->int return 1 end\nexport one, missing",
    "if true then export fn local()->int return 1 end end",
};
pub const process_count = 8 + invalid.len;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("imports/library",
        \\import drawing.drawing
        \\import paint.{draw, label, picture};print("imported once")
        \\export fn make(width:length)->picture
        \\  pic:=picture(width,20mm)
        \\  drawing pic do +draw (0mm,0mm)--(width,20mm) end
        \\  object.append(pic, object.label(typ[Imported text Ω], (2mm,10mm)))
        \\  return pic
        \\end
        \\fn add(a:int,b:int)->int return a+b end
        \\fn twice(a:int)->int return 2*a end
        \\fn hidden()->int return 0 end
        \\mixfix _ add _ in addition
        \\mixfix twice _ in unary
        \\export add, twice
    );
    const selected = try ctx.script("imports/selected",
        \\import assertions.assert
        \\import "library.huak" as shapes
        \\import "library.huak".{make as create, add as plus}
        \\import "library.huak".twice
        \\assert(twice 3==6)
        \\assert(2 plus 3==5)
        \\default create(50mm)
        \\export mirror:=shapes.make(50mm)
    );
    _ = try ctx.command("check", selected, &.{}, true);
    const result = try ctx.command("run", selected, &.{ "--output", "selected-import.svg", "--output", "selected-import.pdf", "--output", "mirror=selected-mirror.svg" }, true);
    try h.output(result, "imported once\n");
    try t.expect((try ctx.svg("selected-import.svg")).count("path") > 0);
    _ = try ctx.svg("selected-mirror.svg");
    try h.contains(try ctx.pdfText("selected-import.pdf", false), "Imported text Ω");
    try h.contains((try ctx.command("disassemble", selected, &.{}, true)).stdout, "call");

    const all = try ctx.script("imports/all",
        \\import assertions.assert
        \\import "library.huak".*
        \\assert(1 add 2==3)
        \\assert(twice 5==10)
        \\default make(20mm)
    );
    try h.output(try ctx.command("run", all, &.{ "--output", "wildcard-import.svg" }, true), "imported once\n");
    _ = try ctx.svg("wildcard-import.svg");
    const inferred = try ctx.script("imports/inferred", "import \"library.huak\"\ndefault library.make(10mm)");
    _ = try ctx.command("check", inferred, &.{}, true);

    const named = try ctx.script("imports/named", "import paint\nexport p:=picture(640, 480);default p\nobject.append(p, copy(paint.sphere(5mm)))");
    _ = try ctx.command("run", named, &.{ "--output", "namespace-paint.svg" }, true);
    _ = try ctx.svg("namespace-paint.svg");
    const renamed = try ctx.script("imports/renamed", "import paint.sphere as ball\nexport p:=picture(640, 480);default p\nobject.append(p, copy(ball 5mm))");
    _ = try ctx.command("run", renamed, &.{ "--output", "prefix-paint.svg" }, true);
    _ = try ctx.svg("prefix-paint.svg");
    const group = try ctx.script("imports/group", "import paint.{rgb, circle};import paint.{filled as colored, shifted}\nexport p:=picture(640, 480);default p\nobject.append(p, copy(circle((0mm,0mm),5mm) colored rgb(1,0,0) shifted (10mm,0mm)))");
    _ = try ctx.command("run", group, &.{ "--output", "infix-paint.svg" }, true);
    _ = try ctx.svg("infix-paint.svg");

    for (invalid, 0..) |source, index| {
        const path = try ctx.script(try ctx.fmt("imports/invalid-{d}", .{index}), source);
        try h.output(try ctx.command("check", path, &.{}, false), "");
    }
}
