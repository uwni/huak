//! A batch shares source modules and retained text, then exports independent
//! pictures and aliases through actual serial and parallel CLI invocations.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

pub const process_count = 8;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("batch/shared",
        \\setup_typst { set text(size: 15pt) }
        \\export caption := typ[Batch shared $x^2$]
    );
    _ = try ctx.script("batch/first",
        \\import paint.{rgb, rectangle, fill, label, picture};import "shared.huak" as shared
        \\export pic := picture(180, 80)
        \\object.append(pic, object.fill(rectangle((0,0),180,80), rgb(1,1,1)))
        \\object.append(pic, object.label(shared.caption, (12,35)))
        \\default pic
    );
    _ = try ctx.script("batch/second",
        \\import paint.{draw, label, picture};import "shared.huak" as shared
        \\export pic := picture(220, 100)
        \\object.append(pic, object.draw((0,0) ~~ (70,45) ~~ (160,15)))
        \\object.append(pic, object.label(shared.caption, (20,60)))
        \\default pic
    );
    const script = try ctx.script("batch/main",
        \\import paint.{label, picture, timeline, animate};import "first.huak" as first
        \\import "second.huak" as second
        \\import "shared.huak" as shared
        \\export a := first.pic
        \\export alias := first.pic
        \\export b := second.pic
        \\export moving := picture(240,100)
        \\moving.timeline(2,false)
        \\id:=object.append(moving, object.label(shared.caption, (12,35)))
        \\animate(id,"translate",[[0,(0,0)],[1,(100,0)]])
    );
    _ = try ctx.command("run", script, &.{
        "--jobs=1",                                "--output=a=batch-serial-a.svg", "--output=alias=batch-serial-alias.svg",
        "--output=b=batch-serial-b.svg",           "--output=a=batch-serial-a.pdf", "--output=b=batch-serial-b.pdf",
        "--output=moving=batch-serial-moving.svg",
    }, true);
    _ = try ctx.command("run", script, &.{
        "--jobs=4",                                  "--output=a=batch-parallel-a.svg", "--output=alias=batch-parallel-alias.svg",
        "--output=b=batch-parallel-b.svg",           "--output=a=batch-parallel-a.pdf", "--output=b=batch-parallel-b.pdf",
        "--output=moving=batch-parallel-moving.svg",
    }, true);
    for ([_][]const u8{ "a", "alias", "b", "moving" }) |name| {
        const serial = try ctx.fmt("batch-serial-{s}.svg", .{name});
        const parallel = try ctx.fmt("batch-parallel-{s}.svg", .{name});
        try t.expectEqualStrings(try ctx.read(serial), try ctx.read(parallel));
        _ = try ctx.svg(parallel);
    }
    try t.expectEqualStrings(try ctx.read("batch-parallel-a.svg"), try ctx.read("batch-parallel-alias.svg"));
    try (try ctx.svg("batch-parallel-a.svg")).viewBox("0 0 180 80");
    try (try ctx.svg("batch-parallel-b.svg")).viewBox("0 0 220 100");
    try t.expectEqual(@as(usize, 1), (try ctx.svg("batch-parallel-moving.svg")).count("animateTransform"));
    for ([_][]const u8{ "a", "b" }) |name| {
        const serial = try ctx.pdfText(try ctx.fmt("batch-serial-{s}.pdf", .{name}), false);
        const parallel = try ctx.pdfText(try ctx.fmt("batch-parallel-{s}.pdf", .{name}), false);
        try h.contains(parallel, "Batch shared");
        try t.expectEqualStrings(serial, parallel);
    }

    // Repeated invocations cover alias counts and last-user cleanup without
    // retaining any output buffers in the executing process between runs.
    for (0..3) |_| {
        _ = try ctx.command("run", script, &.{ "-j3", "--output=a=batch-repeat-a.svg", "--output=alias=batch-repeat-alias.pdf", "--output=b=batch-repeat-b.pdf", "--output=moving=batch-repeat-moving.svg" }, true);
    }
    try t.expectEqualStrings(try ctx.read("batch-parallel-a.svg"), try ctx.read("batch-repeat-a.svg"));
    try h.contains(try ctx.pdfText("batch-repeat-alias.pdf", false), "Batch shared");

    // All selected targets are validated before any output starts. A valid
    // picture appearing first must not leave a file after an animated PDF.
    const preflight = try ctx.command("run", script, &.{ "--jobs=4", "--output=a=batch-preflight.svg", "--output=moving=batch-preflight.pdf" }, false);
    try h.contains(preflight.stderr, "AnimationRequiresSvg");
    try ctx.absent("batch-preflight.svg");
    try ctx.absent("batch-preflight.pdf");

    // A real write failure must join active workers and exit normally. Other
    // in-flight exports may complete; any completed files must be valid.
    try ctx.temporary.dir.createDir(t.io, "batch-blocked.svg", .default_dir);
    try ctx.write("batch-blocked.svg/marker", "directory must survive");
    const failed = try ctx.command("run", script, &.{ "--jobs=4", "--output=a=batch-blocked.svg", "--output=alias=batch-inflight-a.svg", "--output=b=batch-inflight-b.pdf", "--output=moving=batch-inflight-moving.svg" }, false);
    try h.contains(failed.stderr, "cannot write");
    try h.contains(failed.stderr, "batch-blocked.svg");
    try t.expectEqualStrings("directory must survive", try ctx.read("batch-blocked.svg/marker"));
    if (try ctx.exists("batch-inflight-a.svg")) _ = try ctx.svg("batch-inflight-a.svg");
    if (try ctx.exists("batch-inflight-b.pdf")) try h.contains(try ctx.pdfText("batch-inflight-b.pdf", false), "Batch shared");
    if (try ctx.exists("batch-inflight-moving.svg")) _ = try ctx.svg("batch-inflight-moving.svg");

    // Keep existing output-path semantics when rendering through a symlink.
    try ctx.write("batch-link-target.svg", "old output");
    try ctx.temporary.dir.symLink(t.io, "batch-link-target.svg", "batch-link.svg", .{});
    _ = try ctx.command("run", script, &.{ "--jobs=2", "--output=a=batch-link.svg", "--output=b=batch-link-b.svg" }, true);
    try t.expectEqualStrings(try ctx.read("batch-parallel-a.svg"), try ctx.read("batch-link-target.svg"));
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link_length = try ctx.temporary.dir.readLink(t.io, "batch-link.svg", &link_buffer);
    try t.expectEqualStrings("batch-link-target.svg", link_buffer[0..link_length]);
}
