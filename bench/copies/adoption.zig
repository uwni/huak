//! Case task_adoption: adopting a task's picture into the coordinating runtime.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");

// Measure the coordinator handoff separately from layout and export. All text
// owners are real native layouts; the child dies before the result is rendered.
pub fn adoptionCase(init: std.process.Init, library: *typst.Library) !void {
    const l = huak.language;
    const rounds = 8;
    for ([_]struct { created: usize, retained: usize, copies: usize = 1 }{
        .{ .created = 0, .retained = 0 },
        .{ .created = 1, .retained = 1 },
        .{ .created = 64, .retained = 64 },
        .{ .created = 1024, .retained = 1024 },
        .{ .created = 4096, .retained = 4096 },
        .{ .created = 1, .retained = 1, .copies = 4096 },
        .{ .created = 4096, .retained = 1 },
    }) |case| {
        var elapsed: i96 = 0;
        var allocated: usize = 0;
        var digest: [32]u8 = undefined;
        for (0..rounds) |round| {
            var counted = std.testing.FailingAllocator.init(init.gpa, .{});
            const a = counted.allocator();
            var parent = try l.Runtime.init(a, a, library, .{});
            defer parent.deinit();
            _ = try parent.host().typeset(a, .{ .source = "[Borrowed caption]" });
            var child = try parent.forkTask();
            var alive = true;
            defer if (alive) child.deinit();
            const host = child.host();
            const result = try host.callBuiltin(a, .picture, &.{ .{ .number = 100 }, .{ .number = 100 } }, null);
            for (0..case.created) |index| {
                const text = try host.typeset(a, .{ .source = "[Worker text $x^2$]" });
                if (index >= case.retained) continue;
                for (0..case.copies) |copy| {
                    const label = index * case.copies + copy;
                    const object = try host.callBuiltin(a, .label, &.{ text, .{ .vec2 = .{ .x = @floatFromInt(label % 64), .y = @floatFromInt(label / 64) } } }, null);
                    _ = try host.callBuiltin(a, .append, &.{ result, object }, null);
                }
            }
            const before = counted.allocated_bytes;
            const start = std.Io.Clock.awake.now(init.io);
            const adopted = try parent.adoptTask(&child, result);
            const end = std.Io.Clock.awake.now(init.io);
            elapsed += start.durationTo(end).toNanoseconds();
            allocated += counted.allocated_bytes - before;
            child.deinit();
            alive = false;
            if (parent.layouts.items.len != case.retained + 1) return error.IncorrectLayoutCount;
            var svg = try parent.render(adopted, .svg);
            defer svg.deinit();
            var actual: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(svg.bytes(), &actual, .{});
            if (round == 0) digest = actual else if (!std.mem.eql(u8, &digest, &actual)) return error.NonEquivalentResult;
        }
        std.debug.print("case=task_adoption created={d} retained={d} copies={d} rounds={d} us={d:.3} allocated_bytes={d} svg_hash={x}\n", .{
            case.created, case.retained, case.copies, rounds, @as(f64, @floatFromInt(elapsed)) / (rounds * 1000), allocated / rounds, digest,
        });
    }
}
