//! Real CLI construction workers, imported builders and shared dependency DAGs.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

pub const process_count = 4;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("workers/figures",
        \\import paint.{translate, draw, label, picture, append};print("worker module initialized")
        \\setup_typst { set text(size: 14pt) }
        \\export caption:=typ[Worker shared label Ω $x^2$]
        \\fn figure(index:int) -> picture
        \\ p:=picture(180,100)
        \\ for stroke in 0:39 do
        \\  y:=4+stroke*1.5
        \\  object.append(p, object.draw((4,y)~~(60,y+index)~~(120,y-index)~~(176,y)))
        \\ end
        \\ object.append(p, object.label(caption, (8,80)))
        \\ return p
        \\end
        \\export figure
        \\fn combined(left:picture,right:picture) -> picture
        \\ p:=picture(200,120)
        \\ p.append(copy(left))
        \\ p.append(copy(right), translate((3,3)))
        \\ return p
        \\end
        \\export combined
    );
    const script = try ctx.script("workers/main",
        \\import paint.draw;import "figures.huak" as art
        \\import "./figures.huak" as again
        \\export first:=art.figure(1)
        \\export second:=again.figure(2)
        \\left:=art.combined(first,second)
        \\right:=again.combined(first,second)
        \\export final:=art.combined(left,right)
        \\object.append(final, object.draw((1,1)--(195,115)))
        \\export alias:=final
        \\default final
    );
    const serial = try ctx.command("run", script, &.{
        "--jobs=1",                                "--output=workers-serial.svg",             "--output=first=workers-first-serial.svg",
        "--output=final=workers-final-serial.svg", "--output=alias=workers-alias-serial.svg", "--output=final=workers-serial.pdf",
    }, true);
    try h.output(serial, "worker module initialized\n");
    const parallel = try ctx.command("run", script, &.{
        "--jobs=4",                                  "--output=workers-parallel.svg",             "--output=first=workers-first-parallel.svg",
        "--output=final=workers-final-parallel.svg", "--output=alias=workers-alias-parallel.svg", "--output=final=workers-parallel.pdf",
    }, true);
    try h.output(parallel, "worker module initialized\n");
    for ([_][]const u8{ "workers", "workers-first", "workers-final", "workers-alias" }) |prefix| {
        const a = try ctx.fmt("{s}-serial.svg", .{prefix});
        const b = try ctx.fmt("{s}-parallel.svg", .{prefix});
        try t.expectEqualStrings(try ctx.read(a), try ctx.read(b));
        _ = try ctx.svg(b);
    }
    try t.expectEqualStrings(try ctx.read("workers-parallel.svg"), try ctx.read("workers-alias-parallel.svg"));
    try (try ctx.svg("workers-parallel.svg")).viewBox("0 0 200 120");
    const serial_text = try ctx.pdfText("workers-serial.pdf", false);
    const parallel_text = try ctx.pdfText("workers-parallel.pdf", false);
    try h.contains(parallel_text, "Worker shared label");
    try h.contains(parallel_text, "Ω");
    try t.expectEqualStrings(serial_text, parallel_text);

    const broken = try ctx.script("workers/broken",
        \\import paint.{label, picture};import "figures.huak" as art
        \\fn broken() -> picture
        \\ p:=picture(180,100)
        \\ object.append(p, object.label(typ[#missing_worker_name], (8,80)))
        \\ return p
        \\end
        \\export first:=art.figure(1)
        \\export second:=broken()
        \\export third:=art.figure(2)
    );
    const serial_failure = try ctx.command("run", broken, &.{ "--jobs=1", "--output=first=worker-error-before-serial.svg", "--output=second=worker-error-serial.svg" }, false);
    const parallel_failure = try ctx.command("run", broken, &.{ "--jobs=4", "--output=first=worker-error-before-parallel.svg", "--output=second=worker-error-parallel.svg" }, false);
    try h.contains(parallel_failure.stderr, "missing_worker_name");
    try h.contains(parallel_failure.stderr, "broken");
    try t.expectEqualStrings(serial_failure.stderr, parallel_failure.stderr);
    for ([_][]const u8{ "worker-error-before-serial.svg", "worker-error-before-parallel.svg", "worker-error-serial.svg", "worker-error-parallel.svg" }) |name| try ctx.absent(name);
}
