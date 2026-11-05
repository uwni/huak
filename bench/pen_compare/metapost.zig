//! MetaPost source emission only. No external program is used by huak itself.
const std = @import("std");
const inputs = @import("cases.zig");

fn point(writer: *std.Io.Writer, value: inputs.Point) !void {
    try writer.print("({d},{d})", .{ value.x, value.y });
}

fn same(first: inputs.Point, last: inputs.Point) bool {
    return first.x == last.x and first.y == last.y;
}

fn pathSource(writer: *std.Io.Writer, path: inputs.core.Path) !void {
    var first: inputs.Point = .zero;
    var completed_cycle = false;
    for (path.segments.items, 0..) |segment, index| {
        const final_drawable = index + 2 == path.segments.items.len and path.segments.items[index + 1] == .close;
        switch (segment) {
            .move => |value| {
                first = value;
                try point(writer, value);
            },
            .line => |value| {
                try writer.writeAll("--");
                if (final_drawable and same(value, first)) {
                    try writer.writeAll("cycle");
                    completed_cycle = true;
                } else try point(writer, value);
            },
            .cubic => |curve| {
                try writer.writeAll("..controls ");
                try point(writer, curve.c1);
                try writer.writeAll(" and ");
                try point(writer, curve.c2);
                try writer.writeAll("..");
                if (final_drawable and same(curve.end, first)) {
                    try writer.writeAll("cycle");
                    completed_cycle = true;
                } else try point(writer, curve.end);
            },
            .close => if (!completed_cycle) try writer.writeAll("--cycle"),
        }
    }
}

pub fn source(allocator: std.mem.Allocator, case: inputs.Case, repeats: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("tracingonline:=0;\nprologues:=3;\npath p,q; pen nib;\np:=");
    var path = try inputs.path(allocator, case);
    defer path.deinit();
    try pathSource(writer, path);
    try writer.print(";\nif length p <> {d}: errmessage \"centerline segment count differs\"; fi;\nnib:=makepen(", .{path.segmentCount()});
    var buffer: [16]inputs.Point = undefined;
    for (inputs.vertices(case, &buffer), 0..) |vertex, index| {
        if (index != 0) try writer.writeAll("--");
        try point(writer, vertex);
    }
    try writer.writeAll("--cycle);\nlinejoin:=rounded; linecap:=rounded; miterlimit:=4;\nq:=p;\n");
    if (case.mode == .stroke and inputs.closed(case)) try writer.writeAll(
        \\vardef stroke_cut(expr center)=
        \\ save selected,incoming,outgoing,knot;
        \\ numeric selected; pair incoming,outgoing,knot;
        \\ selected:=-1;
        \\ for i=0 upto length center-1:
        \\  knot:=point i of center;
        \\  incoming:=knot-precontrol i of center;
        \\  outgoing:=postcontrol i of center-knot;
        \\  if (selected<0) and (incoming<>origin) and (outgoing<>origin):
        \\   if (xpart incoming*ypart outgoing=ypart incoming*xpart outgoing)
        \\    and (xpart incoming*xpart outgoing+ypart incoming*ypart outgoing>0):
        \\    selected:=i;
        \\   fi;
        \\  fi;
        \\  exitif selected>=0;
        \\ endfor
        \\ if selected<0: selected:=.5; fi;
        \\ selected
        \\enddef;
        \\numeric cut;
        \\
    );
    if (case.mode == .stroke and inputs.closed(case)) {
        // Select and open on every iteration, as the production full stroke
        // does. The closed cases have direct nonzero knot tangents or a
        // regular first edge for the interior fallback.
        try writer.print("for iteration=1 upto {d}:\n cut:=stroke_cut(p);\n q:=envelope nib of (subpath (cut,length p+cut) of p);\nendfor\n", .{repeats});
    } else {
        try writer.print("for iteration=1 upto {d}:\n q:=envelope nib of ", .{repeats});
        try writer.writeAll("p");
        try writer.writeAll(";\nendfor\n");
    }
    // Export only the final result, outside the repeated envelope calculation.
    // Its controls are read and compared by the parent process after timing.
    try writer.writeAll(
        \\string file; file:="mp-result.csv";
        \\for i=0 upto length q-1:
        \\ save a,b,c,d; pair a,b,c,d;
        \\ a:=point i of q; b:=postcontrol i of q;
        \\ c:=precontrol (i+1) of q; d:=point (i+1) of q;
        \\ write decimal xpart a & "," & decimal ypart a & ","
        \\ & decimal xpart b & "," & decimal ypart b & ","
        \\ & decimal xpart c & "," & decimal ypart c & ","
        \\ & decimal xpart d & "," & decimal ypart d to file;
        \\endfor
        \\write EOF to file;
        \\end
        \\
    );
    return output.toOwnedSlice();
}

test "MetaPost benchmark closes the final cubic without a zero length segment" {
    const allocator = std.testing.allocator;
    const case = inputs.cases[0];
    var path = try inputs.path(allocator, case);
    defer path.deinit();
    try std.testing.expectEqual(@as(usize, 4), path.segmentCount());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try pathSource(&output.writer, path);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "..cycle"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, output.written(), "..controls "));
    try std.testing.expect(!std.mem.containsAtLeast(u8, output.written(), 1, "--cycle"));
}

test "MetaPost benchmark closes explicit final lines without duplicating their knot" {
    const allocator = std.testing.allocator;
    var path = inputs.core.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.zero);
    try path.close();
    try std.testing.expectEqual(@as(usize, 2), path.segmentCount());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try pathSource(&output.writer, path);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "--cycle"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "--"));
}

test "MetaPost benchmark retains a nonzero implicit closing edge" {
    const allocator = std.testing.allocator;
    const case = inputs.cases[1];
    var path = try inputs.path(allocator, case);
    defer path.deinit();
    try std.testing.expectEqual(@as(usize, 5), path.segmentCount());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try pathSource(&output.writer, path);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "--cycle"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, output.written(), "--"));
}

test "MetaPost benchmark input coordinates retain all binary precision" {
    const value: inputs.Point = .{ .x = 4 * @cos(std.math.pi / 2.0), .y = 1.0 / 3.0 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try point(&output.writer, value);
    const bytes = output.written();
    var fields = std.mem.splitScalar(u8, bytes[1 .. bytes.len - 1], ',');
    const x = try std.fmt.parseFloat(f64, fields.next().?);
    const y = try std.fmt.parseFloat(f64, fields.next().?);
    try std.testing.expectEqual(@as(u64, @bitCast(value.x)), @as(u64, @bitCast(x)));
    try std.testing.expectEqual(@as(u64, @bitCast(value.y)), @as(u64, @bitCast(y)));
}

test "MetaPost benchmark selects the closed stroke seam inside each iteration" {
    const allocator = std.testing.allocator;
    const bytes = try source(allocator, inputs.cases[4], 17);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "for iteration=1 upto 17:\n cut:=stroke_cut(p);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "subpath (cut,length p+cut) of p"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, bytes, 1, "subpath (0.5"));
}
