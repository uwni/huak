//! Native path queries through namespace imports, bytecode and CLI diagnostics.
const h = @import("harness.zig");

const invalid = [_]struct { expression: []const u8, message: []const u8 }{
    .{ .expression = "closed(compound([]))", .message = "InvalidPath" },
    .{ .expression = "closed(closed(curve))", .message = "InvalidPath" },
    .{ .expression = "sample_at_length(curve,-1pt)", .message = "InvalidParameter" },
    .{ .expression = "sample_at_length(curve,11pt)", .message = "InvalidParameter" },
    .{ .expression = "sample_at_fraction(curve,1.1)", .message = "InvalidParameter" },
    .{ .expression = "sample_at_fraction(compound([]),0.0)", .message = "EmptyPath" },
    .{ .expression = "sample_at_length(curve,1pt,0pt)", .message = "InvalidTolerance" },
    .{ .expression = "samples_at_length(curve,[1pt,2deg])", .message = "DimensionMismatch" },
    .{ .expression = "samples_at_length(curve,[0pt,11pt])", .message = "InvalidParameter" },
    .{ .expression = "intersection_times(curve,cross,0pt)", .message = "NonFinite" },
};
const invalid_units = [_][]const u8{
    "sample_at_length(curve,1deg)",
    "sample_at_fraction(curve,1pt)",
    "sample_at_fraction(curve,0.5,1deg)",
    "intersection_times(curve,cross,1deg)",
};
pub const process_count = 3 + invalid.len + invalid_units.len;

pub fn run(ctx: *h.Harness) !void {
    const script = try ctx.script("path_queries/main",
        \\import geometry as geo
        \\import geometry.{path, compound, point_at, sample_path, samples_at_length, closed as seal, intersection_times as crossings, sample_at_length as at_length, sample_at_fraction as at_fraction}
        \\import assertions.assert
        \\import math.{abs, norm}
        \\fn check_sample(curve:path,row:list)->void
        \\    assert(len(row)==5)
        \\    assert(norm(row[1]-curve.point_at(row[3]))<0.000001pt)
        \\end
        \\curve:=path((0pt,0pt),(30pt,0pt),(30pt,40pt))
        \\border:=seal(curve:curve)
        \\assert(len(curve)==2 and len(border)==3)
        \\assert(curve.point_at(2)==(30pt,40pt))
        \\assert(border.point_at(3)==(0pt,0pt))
        \\assert(len(curve.seal())==len(geo.closed(curve)))
        \\FOLDED:=2*3
        \\row:=at_fraction(curve,FOLDED/12.0)
        \\assert(row==curve.at_length(distance:35pt,tolerance:0.0001pt))
        \\assert(row==geo.sample_at_fraction(fraction:0.5,curve:curve,tolerance:0.0001pt))
        \\assert(row==sample_path(curve,3,0.0001pt)[1])
        \\assert(row[0]==0.5 and norm(row[1]-(30pt,5pt))<0.000001pt and norm(row[2]-(0,1))<0.000000000001)
        \\assert(row[3]==1.125 and row[4]==0)
        \\check_sample(curve,row)
        \\last:=curve.at_fraction(1.0)
        \\assert(last[0]==1.0 and last[1]==(30pt,40pt) and last[3]==2.0)
        \\check_sample(curve,last)
        \\batch:=curve.samples_at_length(distances:[70pt,0pt,35pt],tolerance:0.0001pt)
        \\assert(len(batch)==3 and batch[0]==last and batch[2]==row)
        \\assert(batch[1][0]==0.0 and batch[1][1]==(0pt,0pt) and batch[1][3]==0.0)
        \\for i in 0:len(batch)-1 do check_sample(curve,batch[i]) end
        \\multi:=compound([path((0pt,0pt),(10pt,0pt)),path((100pt,20pt),(100pt,50pt))])
        \\boundary:=at_length(multi,10pt)
        \\assert(boundary==at_fraction(multi,0.25))
        \\assert(boundary==sample_path(multi,3)[3])
        \\assert(boundary[1]==(100pt,20pt) and boundary[3]==1.0 and boundary[4]==1)
        \\check_sample(multi,boundary)
        \\finish:=at_length(multi,40pt)
        \\assert(finish[1]==(100pt,50pt) and finish[3]==2.0 and finish[4]==1)
        \\check_sample(multi,finish)
        \\stationary:=path((3pt,4pt),(3pt,4pt))
        \\still:=at_fraction(stationary,0.8)
        \\assert(still==at_length(stationary,0pt))
        \\assert(still[0]==0.0 and still[1]==(3pt,4pt) and still[2]==(0,0))
        \\assert(still[3]==1.0 and still[4]==0)
        \\check_sample(stationary,still)
        \\repeated:=path((-2pt,0pt),(2pt,0pt),(-2pt,0pt))
        \\cross:=path((0pt,-2pt),(0pt,2pt))
        \\hits:=crossings(first:repeated,second:cross,tolerance:0.000001pt)
        \\assert(len(hits)==2 and abs(hits[0].x-hits[1].x)>0.9)
        \\assert(hits==repeated.crossings(cross,0.000001pt))
        \\for i in 0:len(hits)-1 do
        \\    hit:=hits[i]
        \\    assert(abs(hit.y-0.5)<0.000001)
        \\    assert(norm(repeated.point_at(hit.x)-cross.point_at(hit.y))<0.000001pt)
        \\end
        \\vertex:=path((-2pt,0pt),(0pt,0pt),(2pt,0pt))
        \\shared:=geo.intersection_times(vertex,cross)
        \\assert(len(shared)==1 and abs(shared[0].x-1.0)<0.000001)
        \\assert(len(geo.intersection_times(curve,path((60pt,0pt),(60pt,40pt))))==0)
        \\print("path queries passed")
    );
    _ = try ctx.command("check", script, &.{}, true);
    const assembly = try ctx.command("disassemble", script, &.{}, true);
    try h.contains(assembly.stdout, "call_builtin");
    try h.excludes(assembly.stdout, "multiply");
    try h.excludes(assembly.stdout, "divide");
    try h.output(try ctx.command("run", script, &.{}, true), "path queries passed\n");

    const preamble = "import geometry.{path,compound,closed,intersection_times,sample_at_length,sample_at_fraction,samples_at_length};curve:=path((0pt,0pt),(10pt,0pt));cross:=path((5pt,-1pt),(5pt,1pt))\n";
    for (invalid, 0..) |case, index| {
        const source = try ctx.fmt("{s}{s}\n", .{ preamble, case.expression });
        const file = try ctx.script(try ctx.fmt("path_queries/invalid-{d}", .{index}), source);
        const failure = try ctx.command("run", file, &.{}, false);
        try h.contains(failure.stderr, case.message);
        try h.output(failure, "");
    }
    for (invalid_units, 0..) |expression, index| {
        const source = try ctx.fmt("{s}{s}\n", .{ preamble, expression });
        const file = try ctx.script(try ctx.fmt("path_queries/units-{d}", .{index}), source);
        const failure = try ctx.command("check", file, &.{}, false);
        try h.contains(failure.stderr, try ctx.fmt("{s}:2:", .{file}));
        try h.output(failure, "");
    }
}
