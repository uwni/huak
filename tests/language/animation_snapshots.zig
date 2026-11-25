//! Animation snapshots: static pictures of the playback state.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const execute = harness.execute;

test "animation snapshots are static pictures of the playback state" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, circle, rectangle, path, fill, filldraw, pen, label, picture, bounds};import animation.{timeline, animate, motion};import math.norm;import assertions.assert
        \\// One second into a 4 s loop: phase 0.25.
        \\pic:=picture(160pt,60pt); pic.timeline(4)
        \\faded:=object.append(pic, fill(circle((20pt,30pt),6pt),rgb(0.2,0.4,0.6)))
        \\animate(faded,"opacity",[[0,0.2],[0.5,1],[1,0]])
        \\tinted:=object.append(pic, fill(rectangle((40pt,24pt),12pt,12pt),rgb(1,0,0)))
        \\animate(tinted,"fill",[[0,rgb(1,0,0)],[1,rgb(0,0,1)]])
        \\held:=object.append(pic, fill(circle((80pt,30pt),6pt),rgb(0,0,0)))
        \\animate(held,"opacity",[[0,1],[0.5,0],[1,1]],"discrete")
        \\hidden:=object.append(pic, fill(circle((110pt,30pt),6pt),rgb(0,0,0)))
        \\animate(hidden,"opacity",[[0,1],[0.2,0],[1,0]],"discrete")
        \\still:=animation.snapshot(pic,1)
        \\expected:=picture(160pt,60pt)
        \\object.append(expected, fill(circle((20pt,30pt),6pt),rgb(0.2,0.4,0.6,0.6)))
        \\object.append(expected, fill(rectangle((40pt,24pt),12pt,12pt),rgb(0.75,0,0.25)))
        \\object.append(expected, fill(circle((80pt,30pt),6pt),rgb(0,0,0)))
        \\// A symmetric easing curve passes its midpoint at half time.
        \\curved:=picture(40pt,40pt); curved.timeline(2)
        \\dot:=object.append(curved, fill(circle((20pt,20pt),6pt),rgb(0,0,0)))
        \\animate(dot,"opacity",[[0,0],[1,1]],[0.42,0,0.58,1])
        \\curved_still:=animation.snapshot(curved,1)
        \\curved_expected:=picture(40pt,40pt)
        \\object.append(curved_expected, fill(circle((20pt,20pt),6pt),rgb(0,0,0,0.5)))
        \\// A quarter cycle ahead, one second into four: halfway.
        \\phased:=picture(40pt,40pt); phased.timeline(4)
        \\lit:=object.append(phased, fill(circle((20pt,20pt),6pt),rgb(0,0,0)))
        \\animate(lit,"opacity",[[0,0],[1,1]],phase:0.25)
        \\phased_still:=animation.snapshot(phased,1)
        \\phased_expected:=picture(40pt,40pt)
        \\object.append(phased_expected, fill(circle((20pt,20pt),6pt),rgb(0,0,0,0.5)))
        \\// Group opacity, as SVG plays it: a picture takes it on; a path with
        \\// two paints and a label each become a picture of their own.
        \\layered:=picture(40pt,40pt); layered.timeline(1)
        \\group:=object.append(layered, picture())
        \\object.append(group, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))
        \\animate(group,"opacity",[[0,0.5],[1,0.5]])
        \\ring:=object.append(layered, filldraw(circle((20pt,20pt),3pt),rgb(0,0,0),pen(rgb(1,0,0),1pt)))
        \\animate(ring,"opacity",[[0,0.5],[1,1]])
        \\hi:=typ[Hi]
        \\words:=object.append(layered, label(hi,(5pt,30pt)))
        \\animate(words,"opacity",[[0,0.25],[1,0.25]])
        \\layered_still:=animation.snapshot(layered,0)
        \\layered_expected:=picture(40pt,40pt)
        \\expected_group:=object.append(layered_expected, picture())
        \\object.append(expected_group, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))
        \\object.opacity(expected_group,0.5)
        \\expected_ring:=object.append(layered_expected, picture())
        \\object.append(expected_ring, filldraw(circle((20pt,20pt),3pt),rgb(0,0,0),pen(rgb(1,0,0),1pt)))
        \\object.opacity(expected_ring,0.5)
        \\expected_words:=object.append(layered_expected, picture())
        \\object.append(expected_words, label(hi,(5pt,30pt)))
        \\object.opacity(expected_words,0.25)
        \\mixed:=picture(40pt,40pt); mixed.timeline(2)
        \\kept:=object.append(mixed, fill(circle((20pt,20pt),6pt),rgb(0,0,0)))
        \\animate(kept,"opacity",[[0,0],[1,1]],smil:true)
        \\// Wrappers nest in declaration order: translate outside scale.
        \\moving:=picture(200pt,200pt); moving.timeline(2,false)
        \\square:=object.append(moving, fill(rectangle((0pt,0pt),10pt,10pt),rgb(0,0,0)))
        \\animate(square,"translate",[[0,(0pt,0pt)],[1,(100pt,0pt)]])
        \\animate(square,"scale",[[0,(1,1)],[1,(3,3)]])
        \\half:=bounds(animation.snapshot(moving,1))
        \\assert(half[0]==(50pt,0pt) and half[1]==(70pt,20pt))
        \\// A single run holds its last keys after the end.
        \\frozen:=bounds(animation.snapshot(moving,9))
        \\assert(frozen[0]==(100pt,0pt) and frozen[1]==(130pt,30pt))
        \\turning:=picture(200pt,200pt); turning.timeline(2)
        \\bar:=object.append(turning, fill(rectangle((10pt,0pt),10pt,10pt),rgb(0,0,0)))
        \\animate(bar,"rotate",[[0,0deg],[1,180deg]])
        \\turned:=bounds(animation.snapshot(turning,1))
        \\assert(norm(turned[0]-(-10pt,10pt))<0.000001pt and norm(turned[1]-(0pt,20pt))<0.000001pt)
        \\travel:=picture(200pt,200pt); travel.timeline(4)
        \\ball:=object.append(travel, fill(circle((0pt,0pt),2pt),rgb(0,0,0)))
        \\motion(ball,path((0pt,0pt),(0pt,80pt)),[[0,0],[1,1]],"none")
        \\placed:=bounds(animation.snapshot(travel,1))
        \\assert(norm(placed[0]-(-2pt,18pt))<0.000001pt and norm(placed[1]-(2pt,22pt))<0.000001pt)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][2][]const u8{ .{ "still", "expected" }, .{ "curved_still", "curved_expected" }, .{ "phased_still", "phased_expected" }, .{ "layered_still", "layered_expected" } }) |pair| {
            var still = try runtime.render(machine.getGlobal(pair[0]).?, .svg);
            defer still.deinit();
            var expected = try runtime.render(machine.getGlobal(pair[1]).?, .svg);
            defer expected.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), still.bytes());
            try t.expect(std.mem.indexOf(u8, still.bytes(), "<animate") == null);
        }
        // The animated source still needs SVG; its snapshot exports as PDF.
        try t.expectError(error.AnimationRequiresSvg, runtime.render(machine.getGlobal("pic").?, .pdf));
        var pdf = try runtime.render(machine.getGlobal("still").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        // Each picture with an opacity is one transparency group in the PDF.
        var layered = try runtime.render(machine.getGlobal("layered_still").?, .pdf);
        defer layered.deinit();
        try t.expectEqual(@as(usize, 2), std.mem.count(u8, layered.bytes(), "/ca 0.5"));
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, layered.bytes(), "/ca 0.25"));
        // The easing list reaches CSS as one cubic-bezier timing curve.
        var curved = try runtime.render(machine.getGlobal("curved").?, .svg);
        defer curved.deinit();
        try t.expect(std.mem.indexOf(u8, curved.bytes(), " 2s cubic-bezier(0.42,0,0.58,1) infinite") != null);
        // A phase starts the loop partway: an inline delay over its start state.
        var phased = try runtime.render(machine.getGlobal("phased").?, .svg);
        defer phased.deinit();
        try t.expect(std.mem.indexOf(u8, phased.bytes(), "opacity=\"0.25\" class=\"huak-a") != null);
        try t.expect(std.mem.indexOf(u8, phased.bytes(), "\" style=\"animation-delay:-1s\"") != null);
        // A track marked smil plays as SMIL and needs no stylesheet.
        var mixed = try runtime.render(machine.getGlobal("mixed").?, .svg);
        defer mixed.deinit();
        try t.expect(std.mem.indexOf(u8, mixed.bytes(), "<animate attributeName=\"opacity\" values=\"0;1\" dur=\"2s\" repeatCount=\"indefinite\"/>") != null);
        try t.expect(std.mem.indexOf(u8, mixed.bytes(), "<style>") == null);
    }
    const failures = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "pic:=picture(40pt,40pt); pic.timeline(1)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"stroke\",[[0,rgb(0,0,0)],[1,rgb(1,0,0)]])\nstill:=animation.snapshot(pic,0.5)", .message = "already has a stroke" },
        .{ .source = "pic:=picture(40pt,40pt)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"opacity\",[[0,0],[1,1]])\nstill:=animation.snapshot(pic,0)", .message = "MissingTimeline" },
        .{ .source = "pic:=picture(40pt,40pt); pic.timeline(1)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"opacity\",[[0,0],[1,1]])\nstill:=animation.snapshot(pic,-1)", .message = "InvalidTiming" },
        .{ .source = "pic:=picture(40pt,40pt)\ndot:=object.append(pic, fill(circle((9pt,9pt),3pt),rgb(0,0,0)))\nanimate(dot,\"opacity\",[[0,0],[1,1]],[0.2,0,1.5,1])", .message = "InvalidEasing" },
    };
    for (failures) |failure| {
        const input = try std.mem.concat(t.allocator, u8, &.{ "import paint.{rgb, circle, fill, picture};import animation.{timeline, animate}\n", failure.source });
        defer t.allocator.free(input);
        var program = try compileModulesOptimized(&library, input, &.{}, false);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const detail = machine.failure.?;
        const reported = std.mem.indexOf(u8, detail.text(), failure.message) != null or std.mem.indexOf(u8, detail.native_message, failure.message) != null;
        if (!reported) std.debug.print("snapshot failure: {s} / {s}\n", .{ detail.text(), detail.native_message });
        try t.expect(reported);
    }
}
