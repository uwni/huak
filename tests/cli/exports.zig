const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
pub fn run(ctx: *h.Harness) !void {
    const baseline = try ctx.fixture("outside_baseline");
    _ = try ctx.command("run", baseline, &.{ "--output", "baseline.pdf" }, true);
    try h.contains(try ctx.pdfText("baseline.pdf", false), "X");
    const drawing = try ctx.fixture("drawing");
    _ = try ctx.command("run", drawing, &.{ "--output", "drawing.svg" }, true);
    const svg = try ctx.svg("drawing.svg");
    try t.expect(svg.count("use") > 0);
    _ = try ctx.command("run", drawing, &.{ "--output", "default=drawing.pdf" }, true);
    try t.expect(std.mem.startsWith(u8, try ctx.read("drawing.pdf"), "%PDF-"));
    try h.contains(try ctx.pdfText("drawing.pdf", true), "CLI selectable text");
    const fonts = try ctx.process(&.{ "pdffonts", try ctx.path("drawing.pdf") });
    try t.expect(fonts.term == .exited and fonts.term.exited == 0);
    var lines = std.mem.splitScalar(u8, fonts.stdout, '\n');
    _ = lines.next();
    _ = lines.next();
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var fields: std.ArrayList([]const u8) = .empty;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        while (words.next()) |word| try fields.append(ctx.allocator(), word);
        try t.expect(fields.items.len >= 5);
        try t.expectEqualStrings("yes", fields.items[fields.items.len - 5]);
        try t.expectEqualStrings("yes", fields.items[fields.items.len - 3]);
        count += 1;
    }
    try t.expect(count > 0);
    _ = try ctx.command("run", drawing, &.{ "--output=pic=both.svg", "--output", "pic=both.pdf" }, true);
    _ = try ctx.svg("both.svg");
    try h.contains(try ctx.pdfText("both.pdf", false), "CLI selectable text");
    const literal = "\"); panic(\"x\")";
    _ = try ctx.command("run", drawing, &.{ "--param", try ctx.fmt("title={s}", .{literal}), "--output", "pic=literal.pdf" }, true);
    try h.contains(try ctx.pdfText("literal.pdf", false), literal);
    try ctx.temporary.dir.deleteFile(t.io, "drawing.svg");
    _ = try ctx.command("run", drawing, &.{}, true);
    try ctx.absent("drawing.svg");
    const malformed = try ctx.fixture("native_error");
    const failure = try ctx.command("run", malformed, &.{}, false);
    try h.contains(failure.stderr, "CompileFailed");
    try h.contains(failure.stderr, "expected");
    const trace = try ctx.fixture("native_trace");
    const native_error = try ctx.command("run", trace, &.{}, false);
    for ([_][]const u8{ "CompileFailed", "unknown_native_value", "broken" }) |word| try h.contains(native_error.stderr, word);
    try ctx.write("invalid.ttf", "invalid font bytes");
    const bad_font = try ctx.command("run", drawing, &.{ "--font", try ctx.path("invalid.ttf"), "--no-bundled-fonts", "--output", "pic=invalid-font.svg" }, false);
    try h.contains(bad_font.stderr, "InvalidArgument");
    try h.contains(bad_font.stderr, "font source");
    try ctx.absent("invalid-font.svg");
    const animation = try ctx.fixture("animation");
    _ = try ctx.command("run", animation, &.{ "--output", "animation.svg" }, true);
    const animated = try ctx.svg("animation.svg");
    var transforms: usize = 0;
    for (animated.elements) |element| {
        if (std.mem.eql(u8, element.name, "animateTransform") and element.attr("keyTimes") != null) {
            transforms += 1;
            try t.expectEqualStrings("translate", element.attr("type").?);
            try t.expectEqualStrings("0;0.37;1", element.attr("keyTimes").?);
            try t.expectEqualStrings("linear", element.attr("calcMode").?);
        }
    }
    try t.expectEqual(@as(usize, 1), transforms);
    try t.expectEqual(@as(usize, 1), animated.count("animate"));
    try t.expectEqual(@as(usize, 1), animated.count("animateMotion"));
    try t.expectEqual(@as(usize, 1), animated.count("svg"));
    try t.expectEqual(@as(usize, 0), animated.count("image"));
    const animated_pdf = try ctx.command("run", animation, &.{ "--output", "pic=animation.pdf" }, false);
    try h.contains(animated_pdf.stderr, "AnimationRequiresSvg");
    try ctx.absent("animation.pdf");
    const explicit = try ctx.fixture("explicit_picture");
    _ = try ctx.command("run", explicit, &.{ "--output", "selected=explicit_picture.svg", "--output", "alias=alias.svg", "--output", "other=other.svg" }, true);
    const chosen = try ctx.svg("explicit_picture.svg");
    try chosen.viewBox("0 0 90 45");
    try t.expect(chosen.hasAttribute("fill", "#ff0000"));
    try t.expect(!chosen.hasAttribute("fill", "#00ff00"));
    const alias = try ctx.svg("alias.svg");
    try t.expectEqual(chosen.count("path"), alias.count("path"));
    const other = try ctx.svg("other.svg");
    try other.viewBox("0 0 200 100");
    try t.expect(other.hasAttribute("fill", "#00ff00"));
    const unselected = try ctx.fixture("unselected_picture");
    _ = try ctx.command("run", unselected, &.{}, true);
    try ctx.absent("unselected_picture.svg");
    const visible = try ctx.fixture("visibility");
    const alias_collision = try ctx.command("run", visible, &.{ "--output", "shown=aliased.svg", "--output", "shown=./aliased.svg" }, false);
    try h.contains(alias_collision.stderr, "duplicate output path");
    try h.output(alias_collision, "");
    try ctx.absent("aliased.svg");
    try ctx.temporary.dir.symLink(t.io, ".", "output-alias", .{ .is_directory = true });
    const symlink_collision = try ctx.command("run", visible, &.{ "--output", "shown=symlinked.svg", "--output", "shown=output-alias/symlinked.svg" }, false);
    try h.contains(symlink_collision.stderr, "duplicate output path");
    try h.output(symlink_collision, "");
    try ctx.absent("symlinked.svg");
    const original = "existing output must survive rejected aliases";
    try ctx.write("hardlink-a.svg", original);
    try ctx.temporary.dir.hardLink("hardlink-a.svg", ctx.temporary.dir, "hardlink-b.pdf", t.io, .{});
    const hardlink_collision = try ctx.command("run", visible, &.{ "--output", "shown=hardlink-a.svg", "--output", "shown=hardlink-b.pdf" }, false);
    try h.contains(hardlink_collision.stderr, "duplicate output path");
    try h.output(hardlink_collision, "");
    try t.expectEqualStrings(original, try ctx.read("hardlink-a.svg"));
    try t.expectEqualStrings(original, try ctx.read("hardlink-b.pdf"));
    try ctx.temporary.dir.symLink(t.io, "new-output.svg", "dangling-output.svg", .{});
    const dangling_collision = try ctx.command("run", visible, &.{ "--output", "shown=dangling-output.svg", "--output", "shown=new-output.svg" }, false);
    try h.contains(dangling_collision.stderr, "duplicate output path");
    try h.output(dangling_collision, "");
    try ctx.absent("new-output.svg");
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link_length = try ctx.temporary.dir.readLink(t.io, "dangling-output.svg", &link_buffer);
    try t.expectEqualStrings("new-output.svg", link_buffer[0..link_length]);
    try ctx.write("case-probe", "filesystem case probe");
    if (try ctx.exists("CASE-PROBE")) {
        const case_collision = try ctx.command("run", visible, &.{ "--output", "shown=Case-Output.svg", "--output", "shown=case-output.svg" }, false);
        try h.contains(case_collision.stderr, "duplicate output path");
        try h.output(case_collision, "");
        try ctx.absent("Case-Output.svg");
        try ctx.absent("case-output.svg");
    }
    try ctx.write("unicode-case-probe-É", "filesystem Unicode case probe");
    if (try ctx.exists("unicode-case-probe-é")) {
        const unicode_case_collision = try ctx.command("run", visible, &.{ "--output", "shown=É-output.svg", "--output", "shown=é-output.svg" }, false);
        try h.contains(unicode_case_collision.stderr, "duplicate output path");
        try h.output(unicode_case_collision, "");
        try ctx.absent("É-output.svg");
        try ctx.absent("é-output.svg");
        try noOutputProbes(ctx);
    }
    try ctx.write("unicode-normalization-probe-é", "filesystem Unicode normalization probe");
    if (try ctx.exists("unicode-normalization-probe-e\u{301}")) {
        const normalization_collision = try ctx.command("run", visible, &.{ "--output", "shown=normal-é.svg", "--output", "shown=normal-e\u{301}.svg" }, false);
        try h.contains(normalization_collision.stderr, "duplicate output path");
        try h.output(normalization_collision, "");
        try ctx.absent("normal-é.svg");
        try ctx.absent("normal-e\u{301}.svg");
        try noOutputProbes(ctx);
    }
    _ = try ctx.command("run", visible, &.{ "--output", "shown=图甲.svg", "--output", "shown=图乙.svg" }, true);
    _ = try ctx.svg("图甲.svg");
    _ = try ctx.svg("图乙.svg");
    try noOutputProbes(ctx);
    _ = try ctx.command("run", visible, &.{ "--output", "hidden=hidden.svg" }, true);
    _ = try ctx.svg("hidden.svg");
    for ([_][]const u8{"missing"}) |name| {
        const failed = try ctx.command("run", visible, &.{ "--output", try ctx.fmt("{s}={s}.svg", .{ name, name }) }, false);
        try h.contains(failed.stderr, "output");
        try h.contains(failed.stderr, name);
        try h.output(failed, "");
        try ctx.absent(try ctx.fmt("{s}.svg", .{name}));
    }
    const missing_default = try ctx.command("run", visible, &.{ "--output", "without-default.svg" }, false);
    try h.contains(missing_default.stderr, "default");
    try h.output(missing_default, "");
    try ctx.absent("without-default.svg");
    _ = try ctx.command("run", visible, &.{}, true);
    const scalar = try ctx.command("run", visible, &.{ "--output", "shown=valid.svg", "--output", "answer=scalar.pdf" }, false);
    try h.contains(scalar.stderr, "picture");
    try h.contains(scalar.stderr, "answer");
    try ctx.absent("valid.svg");
    try ctx.absent("scalar.pdf");
    const scoped = try ctx.fixture("block_output");
    _ = try ctx.command("run", scoped, &.{}, true);
    const absent = try ctx.command("run", scoped, &.{ "--output", "good=before-uninitialized.svg", "--output", "pending=uninitialized.svg" }, false);
    try h.contains(absent.stderr, "not defined");
    try h.contains(absent.stderr, "pending");
    try ctx.absent("before-uninitialized.svg");
    try ctx.absent("uninitialized.svg");
    const reassigned = try ctx.fixture("reassigned_export");
    _ = try ctx.command("run", reassigned, &.{ "--output", "pic=reassigned.svg" }, true);
    try (try ctx.svg("reassigned.svg")).viewBox("0 0 70 35");
    const defaults = try ctx.fixture("default_export");
    _ = try ctx.command("run", defaults, &.{ "--output", "default-final.svg", "--output", "original=rebound.svg", "--output", "detail=detail.svg", "--output", "detail=detail.pdf" }, true);
    try (try ctx.svg("default-final.svg")).viewBox("0 0 80 40");
    try (try ctx.svg("rebound.svg")).viewBox("0 0 200 100");
    try (try ctx.svg("detail.svg")).viewBox("0 0 120 60");
    try t.expect(std.mem.startsWith(u8, try ctx.read("detail.pdf"), "%PDF-"));
    _ = try ctx.command("run", defaults, &.{ "--output", "default=default=literal.svg" }, true);
    try t.expect(try ctx.exists("default=literal.svg"));
    const expression = try ctx.fixture("default_expression");
    _ = try ctx.command("run", expression, &.{ "--output", "default-expression.svg" }, true);
    try (try ctx.svg("default-expression.svg")).viewBox("0 0 45 25");
    for ([_]struct { name: []const u8, source: []const u8 }{ .{ .name = "duplicate_default", .source = "import paint.picture;default picture(640, 480); default picture(640, 480)\n" }, .{ .name = "reserved_default", .source = "import paint.picture;default=picture(640, 480)\n" } }) |case| {
        const path = try ctx.script(case.name, case.source);
        try h.output(try ctx.command("check", path, &.{}, false), "");
    }
    _ = try ctx.command("run", explicit, &.{ "--output", "selected=has=equals.svg" }, true);
    try t.expect(try ctx.exists("has=equals.svg"));
    const duplicated = try ctx.command("run", explicit, &.{ "--output", "selected=same.svg", "--output", "other=same.svg" }, false);
    try h.contains(duplicated.stderr, "duplicate");
    try ctx.absent("same.svg");
    const empty = try ctx.fixture("empty_picture");
    _ = try ctx.command("run", empty, &.{ "--output", "p=empty_picture.svg" }, true);
    try (try ctx.svg("empty_picture.svg")).viewBox("0 0 40 30");
    const self_append = try ctx.fixture("self_append");
    _ = try ctx.command("run", self_append, &.{}, true);
    const implicit = try ctx.fixture("implicit_drawing");
    try h.contains((try ctx.command("check", implicit, &.{}, false)).stderr, "draw");
    const old_output = try ctx.fixture("removed_output");
    const removed = try ctx.command("check", old_output, &.{}, false);
    try h.contains(removed.stderr, "output");
    try h.contains(removed.stderr, "unknown");
    const old_defer = try ctx.fixture("removed_defer");
    _ = try ctx.command("check", old_defer, &.{}, false);
    try ctx.absent("legacy.svg");
}

fn noOutputProbes(ctx: *h.Harness) !void {
    var directory = try ctx.temporary.dir.openDir(t.io, ".", .{ .iterate = true });
    defer directory.close(t.io);
    var iterator = directory.iterate();
    while (try iterator.next(t.io)) |entry| {
        try t.expect(!std.mem.startsWith(u8, entry.name, ".huak-output-check-"));
    }
}
