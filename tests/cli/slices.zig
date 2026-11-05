const h = @import("harness.zig");

const invalid_syntax = [_][]const u8{
    "xs:=[1,2]; print(xs[0,1])",
    "xs:=[1,2]; print(xs[[0,1]])",
    "xs:=[1,2]; print(xs[:])",
    "xs:=[1,2]; print(xs[0:1:])",
};
const invalid_runtime = [_]struct { source: []const u8, message: []const u8 }{
    .{ .source = "xs:=[1,2]; print(xs[0:0:1])", .message = "step must not be zero" },
    .{ .source = "xs:=[1,2]; print(xs[0:2])", .message = "outside length" },
    .{ .source = "xs:=[1,2]; print(xs[3:])", .message = "outside length" },
    .{ .source = "xs:=[1,2]; print(xs[-1:1])", .message = "outside length" },
    .{ .source = "fn bad(x:any)->list return [1,2][x:1] end; bad(0.0)", .message = "int" },
    .{ .source = "fn missing()->any return end; xs:=[1,2]; print(xs[0:missing()])", .message = "int" },
};
pub const process_count = 4 + invalid_syntax.len + invalid_runtime.len;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("slices/select",
        \\export fn select(values:list,first:int,step:int,last:int)->list
        \\    return values[first:step:last]
        \\end
    );
    const path = try ctx.script("slices/main",
        \\import paint.{path, draw, label, picture};import assertions.assert
        \\import "select.huak".select
        \\param first:int=1
        \\values:=[10,20,30,40,50]
        \\expected:=[]
        \\for i in first:2:4 do expected+=values[i] end
        \\assert(select(values,first,2,4)==expected)
        \\assert(values[first:]==[20,30,40,50])
        \\assert(values[4:-2:0]==[50,30,10])
        \\assert(values[0:4][1:2]==[20,30])
        \\assert(values[5:]==[])
        \\points:=[(2mm,2mm),(10mm,12mm),(20mm,3mm),(30mm,15mm),(38mm,2mm)]
        \\fn figure(input:list,start:int)->picture
        \\    result:=picture(40mm,25mm)
        \\    object.append(result, object.draw(path(input[start:])))
        \\    object.append(result, object.label(typ[Slice paths], (2mm,20mm)))
        \\    return result
        \\end
        \\export first_picture :=figure(points,0)
        \\default first_picture
        \\export second_picture:=figure(points,1)
    );
    _ = try ctx.command("check", path, &.{}, true);
    _ = try ctx.command("run", path, &.{ "-j1", "--output", "slices-serial.svg" }, true);
    const serial = try ctx.read("slices-serial.svg");
    _ = try ctx.command("run", path, &.{ "-j4", "--output", "slices-parallel.svg", "--output", "second_picture=slices.pdf" }, true);
    _ = try ctx.svg("slices-parallel.svg");
    const parallel = try ctx.read("slices-parallel.svg");
    try @import("std").testing.expectEqualSlices(u8, serial, parallel);
    try h.contains(try ctx.pdfText("slices.pdf", false), "Slice paths");
    try h.contains((try ctx.command("disassemble", path, &.{}, true)).stdout, "slice");
    for (invalid_syntax, 0..) |source, index| {
        const script = try ctx.script(try ctx.fmt("slices/syntax-{d}", .{index}), source);
        _ = try ctx.command("check", script, &.{}, false);
    }
    for (invalid_runtime, 0..) |item, index| {
        const script = try ctx.script(try ctx.fmt("slices/runtime-{d}", .{index}), item.source);
        try h.contains((try ctx.command("run", script, &.{}, false)).stderr, item.message);
    }
}
