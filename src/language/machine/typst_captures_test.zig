//! Tests of Typst captures, whole-huak use and typ.module snapshots.
const std = @import("std");
const units = @import("../../drawing/units.zig");
const types = @import("../types.zig");
const Type = types.Type;
const Machine = @import("../Machine.zig");
const testing = @import("testing.zig");
const TypstBatchProbe = testing.TypstBatchProbe;

test "Typst requests tell the host when the code uses huak as a whole value" {
    const input =
        \\title:="t"
        \\a:=typ[#repr(huak)]
        \\b:=typ[#huak.title]
        \\c:=typ[#repr(huak) #huak.title]
        \\d:=typ[plain]
        \\lib:=typ.module[#let all = huak]
        \\other:=typ.module[#let nothing = 1]
    ;
    for ([_]bool{ false, true }) |optimize| for ([_]bool{ false, true }) |batched| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(batched), .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqualSlices(bool, &.{ true, false, true, false }, probe.whole[0..probe.seen_count]);
        try std.testing.expectEqual(@as(usize, 0), probe.captures[0].len);
        try std.testing.expectEqual(@as(usize, 1), probe.captures[2].len);
        try std.testing.expectEqual(@as(usize, 2), probe.module_count);
        try std.testing.expect(probe.modules[0].whole and !probe.modules[1].whole);
    };
}

test "Typst captures batch current scalar snapshots and local shadows without changing VM accounting" {
    const input =
        \\param initial:int=2
        \\count:=initial
        \\title:="first"
        \\a:=typ[A #huak.count #huak.title]
        \\b:=typ[B #huak.count #huak.title]
        \\count=7;title="second"
        \\c:=typ[C #huak.count #huak.title]
        \\d:=typ[D #huak.count #huak.title]
        \\fn make_caption(count:int)->text
        \\title:="local"
        \\x:=typ[X #huak.count #huak.title]
        \\y:=typ[Y #huak.count #huak.title]
        \\return y
        \\end
        \\result:=make_caption(11)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 0), probe.single_calls);
        try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, probe.batch_sizes[0..probe.batch_count]);
        for ([_]i64{ 2, 2, 7, 7, 11, 11 }, 0..) |count, index| {
            try std.testing.expectEqual(@as(usize, 2), probe.captures[index].len);
            try std.testing.expectEqualStrings("count", probe.captures[index][0].name);
            try std.testing.expectEqual(count, probe.captures[index][0].value.int);
            try std.testing.expectEqualStrings("title", probe.captures[index][1].name);
            try std.testing.expectEqualStrings(if (index < 2) "first" else if (index < 4) "second" else "local", probe.captures[index][1].value.string);
        }
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        _ = try serial.execute(&.{});
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        for (0..probe.seen_count) |index| try std.testing.expectEqualDeep(serial_probe.captures[index], probe.captures[index]);
        for ([_]u64{ 1, 3, 8, 12, 18, 24, 36, 48, 60, 80, 100 }) |limit| {
            var batch_limited: TypstBatchProbe = .{};
            var one_limited: TypstBatchProbe = .{};
            var actual = try Machine.init(std.testing.allocator, &program, batch_limited.host(true), .{ .instructions = limit });
            defer actual.deinit();
            var expected = try Machine.init(std.testing.allocator, &program, one_limited.host(false), .{ .instructions = limit });
            defer expected.deinit();
            const expected_result = expected.execute(&.{});
            const actual_result = actual.execute(&.{});
            if (expected_result) |_| {
                _ = try actual_result;
            } else |err| try std.testing.expectError(err, actual_result);
            try std.testing.expectEqual(expected.steps, actual.steps);
            try std.testing.expectEqualDeep(expected.initialized, actual.initialized);
            if (expected.failure) |failure| try std.testing.expectEqualDeep(failure.diagnostic.span, actual.failure.?.diagnostic.span);
        }
    }
}

test "typ.module values reach the host as snapshots of their reads and typ.show paths batch around content" {
    const input =
        \\size:=2pt
        \\outer:=typ.module[#let style(b) = text(huak.size, b)]
        \\size=5pt
        \\inner:=typ.module[#let style(b) = text(huak.size, b)]
        \\typ.show outer.style
        \\a:=typ[A #huak.size]
        \\c:=typ[C #huak.size]
        \\fn caption()->text
        \\    typ.show inner.page.style
        \\    first:=typ[X #huak.size]
        \\    second:=typ[Y #huak.size]
        \\    return second
        \\end
        \\d:=caption()
    ;
    for ([_]bool{ false, true }) |optimize| {
        for ([_]bool{ false, true }) |batched| {
            var program = try TypstBatchProbe.compile(input, optimize);
            defer program.deinit();
            var probe: TypstBatchProbe = .{};
            var machine = try Machine.init(std.testing.allocator, &program, probe.host(batched), .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            try std.testing.expectEqual(@as(usize, 2), probe.module_count);
            for (probe.modules[0..2], [_]f64{ 2, 5 }, [_]usize{ 1, 3 }, [_][]const u8{ "outer", "inner" }) |module, points, line, name| {
                try std.testing.expectEqualStrings(name, module.name);
                try std.testing.expectEqualStrings("[#let style(b) = text(huak.size, b)]", module.code);
                try std.testing.expectEqual(@as(usize, 1), module.bindings.len);
                try std.testing.expectEqualStrings("size", module.bindings[0].name);
                try std.testing.expectEqual(points, try units.toPoints(module.bindings[0].value.quantity));
                try std.testing.expectEqualStrings("typst-batch-vm.huak", module.origin.name);
                try std.testing.expectEqual(line, module.origin.line);
                try std.testing.expectEqual(@as(usize, "outer:=typ.module".len), module.origin.column);
            }
            if (batched) try std.testing.expectEqualSlices(usize, &.{ 2, 2 }, probe.batch_sizes[0..probe.batch_count]);
            try std.testing.expectEqual(@as(usize, 4), probe.seen_count);
            for (0..4) |index| {
                // Content reads the data current at each typ, then the shows outermost first.
                try std.testing.expectEqual(@as(usize, 1), probe.captures[index].len);
                try std.testing.expectEqual(@as(f64, 5), try units.toPoints(probe.captures[index][0].value.quantity));
                const shows = probe.shows[index];
                try std.testing.expectEqual(@as(usize, if (index < 2) 1 else 2), shows.len);
                const paths = [_][]const u8{ "style", "page.style" };
                for (shows, paths[0..shows.len], 0..) |show, path, position| {
                    try std.testing.expectEqual(Type.typst_module, show.value.handle.kind);
                    try std.testing.expectEqual(position, show.value.handle.index);
                    try std.testing.expectEqualStrings(path, show.path);
                }
            }
        }
    }
}

test "Typst captured batch failure publishes only its successful prefix and does not read later operands early" {
    var program = try TypstBatchProbe.compile("count:=4\nfirst:=typ[First #huak.count]\nsecond:=typ[FAIL second #huak.count]\nthird:=typ[Third #huak.count]\n", false);
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expect(machine.getGlobal("first") != null);
    try std.testing.expect(machine.getGlobal("second") == null);
    try std.testing.expect(machine.getGlobal("third") == null);
    var serial_probe: TypstBatchProbe = .{};
    var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
    defer serial.deinit();
    try std.testing.expectError(error.RuntimeFailed, serial.execute(&.{}));
    try std.testing.expectEqual(serial.steps, machine.steps);
    try std.testing.expectEqualDeep(serial.failure.?.diagnostic.span, machine.failure.?.diagnostic.span);
    try std.testing.expectEqualStrings(serial.failure.?.native_message, machine.failure.?.native_message);
}
