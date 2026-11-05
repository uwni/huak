const h = @import("harness.zig");

const invalid = [_][]const u8{
    "line((0,0),(1,1))",
    "fn typed(values:int...) end; typed(1,\"wrong\")",
    "fn invalid(values..., last:int) end",
    "fn invalid(value) end",
    "fn invalid(first:int,first...) end",
    "fn required(first:int,rest...) end; required()",
};
pub const process_count = 3 + invalid.len;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("variadic/helpers",
        \\import paint.path;export fn route(points:pair...)->path return path(points) end
        \\export fn gather(args...)->list return args end
        \\export fn sum(values:float...)->float
        \\    total:=0.0
        \\    for i in 0:len(values)-1 do total=total+values[i] end
        \\    return total
        \\end
    );
    const path = try ctx.script("variadic/main",
        \\import drawing.drawing
        \\import paint.{path, draw, label, picture};import assertions.assert
        \\import "helpers.huak".{route,gather,sum}
        \\export plate :=picture(60mm,40mm)
        \\default plate
        \\drawing plate do +draw route((1mm,1mm),(20mm,30mm),(50mm,10mm)) end
        \\seed:=(0mm,0mm)
        \\object.append(plate, object.draw(seed.route((10mm,0mm),(30mm,20mm))))
        \\object.append(plate, object.label(typ[Variadic paths], (2mm,35mm)))
        \\assert(len(path((0,0),(10,0)))==1)
        \\assert(len(path([(0,0),(10,0)],false))==1)
        \\assert(sum()==0.0);assert(sum(1,2,3)==6.0)
        \\assert(len(gather())==0)
        \\shared:=[]; rest:=gather(shared,shared); first:=rest[0]; first+=1
        \\assert(len(rest[1])==1)
    );
    _ = try ctx.command("check", path, &.{}, true);
    _ = try ctx.command("run", path, &.{ "--output", "variadic.svg", "--output", "plate=variadic.pdf" }, true);
    _ = try ctx.svg("variadic.svg");
    try h.contains(try ctx.pdfText("variadic.pdf", false), "Variadic paths");
    try h.contains((try ctx.command("disassemble", path, &.{}, true)).stdout, "call");
    for (invalid, 0..) |source, index| {
        const script = try ctx.script(try ctx.fmt("variadic/invalid-{d}", .{index}), source);
        try h.output(try ctx.command("check", script, &.{}, false), "");
    }
}
