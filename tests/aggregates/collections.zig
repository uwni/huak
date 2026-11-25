//! The collections standard module.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");

fn expectKeys(dictionary: *const l.types.Dict, expected: []const []const u8) !void {
    try t.expectEqual(expected.len, dictionary.entries.count());
    for (dictionary.entries.keys(), expected) |actual, wanted| try t.expectEqualStrings(wanted, actual);
}

test "aggregates collections helpers preserve order shallow references and their inputs" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\import collections as collections
        \\shared:=[1]
        \\input:={"first":shared,"preserved":false,"last":{"mark":2}}
        \\got:=collections.get(input,"first",[99])
        \\fallback:=collections.get(input,"absent",shared)
        \\kept:=collections.get(input,"preserved",true)
        \\initial_values:=collections.values(input)
        \\empty_values:=collections.values({})
        \\changed:=collections.setting(input,"new",shared)
        \\replaced:=collections.setting(input,"preserved",true)
        \\second:={"preserved":true,"added":shared,"last":{"other":3}}
        \\merged:=collections.merged(input,second)
        \\merge_empty:=collections.merged(input,{})
        \\fallbacks:={"preserved":true,"added":shared,"tail":{"end":4}}
        \\filled:=collections.defaults(input,fallbacks)
        \\defaults_empty:=collections.defaults(input,{})
        \\input_keys:=keys(input)
        \\second_keys:=keys(second)
        \\fallback_keys:=keys(fallbacks)
        \\shared+=2
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        const input = machine.getGlobal("input").?.dict;
        const second = machine.getGlobal("second").?.dict;
        const fallbacks = machine.getGlobal("fallbacks").?.dict;
        const shared = machine.getGlobal("shared").?;
        try harness.expectInts(shared, &.{ 1, 2 });
        try t.expectEqual(shared.list.owned, machine.getGlobal("got").?.list.owned);
        try t.expectEqual(shared.list.owned, machine.getGlobal("fallback").?.list.owned);
        try t.expect(!machine.getGlobal("kept").?.boolean);
        const initial_values = l.types.sequence(machine.getGlobal("initial_values").?).?;
        try t.expectEqual(@as(usize, 3), initial_values.len);
        try t.expectEqual(shared.list.owned, initial_values[0].list.owned);
        try harness.expectInts(initial_values[0], &.{ 1, 2 });
        try t.expect(!initial_values[1].boolean);
        try t.expectEqual(input.entries.get("last").?.dict, initial_values[2].dict);
        try harness.expectInts(machine.getGlobal("empty_values").?, &.{});
        try harness.expectStrings(machine.getGlobal("input_keys").?, &.{ "first", "preserved", "last" });
        try harness.expectStrings(machine.getGlobal("second_keys").?, &.{ "preserved", "added", "last" });
        try harness.expectStrings(machine.getGlobal("fallback_keys").?, &.{ "preserved", "added", "tail" });
        const changed = machine.getGlobal("changed").?.dict;
        const replaced = machine.getGlobal("replaced").?.dict;
        const merged = machine.getGlobal("merged").?.dict;
        const filled = machine.getGlobal("filled").?.dict;
        try t.expect(input != changed and input != replaced and input != merged and input != filled);
        try t.expect(!input.entries.contains("new") and !input.entries.contains("added"));
        try t.expect(!input.entries.get("preserved").?.boolean);
        try t.expect(second.entries.get("preserved").?.boolean);
        try t.expect(fallbacks.entries.get("preserved").?.boolean);
        try expectKeys(changed, &.{ "first", "preserved", "last", "new" });
        try expectKeys(replaced, &.{ "first", "preserved", "last" });
        try expectKeys(merged, &.{ "first", "preserved", "last", "added" });
        try expectKeys(filled, &.{ "first", "preserved", "last", "added", "tail" });
        try t.expectEqual(shared.list.owned, changed.entries.get("new").?.list.owned);
        try t.expect(replaced.entries.get("preserved").?.boolean);
        try t.expect(merged.entries.get("preserved").?.boolean);
        try t.expectEqual(second.entries.get("last").?.dict, merged.entries.get("last").?.dict);
        try t.expectEqual(shared.list.owned, merged.entries.get("first").?.list.owned);
        try t.expectEqual(shared.list.owned, merged.entries.get("added").?.list.owned);
        try t.expect(!filled.entries.get("preserved").?.boolean);
        try t.expectEqual(input.entries.get("last").?.dict, filled.entries.get("last").?.dict);
        try t.expectEqual(fallbacks.entries.get("tail").?.dict, filled.entries.get("tail").?.dict);
        try t.expectEqual(shared.list.owned, filled.entries.get("added").?.list.owned);
        for ([_][]const u8{ "merge_empty", "defaults_empty" }) |name| {
            const copy = machine.getGlobal(name).?.dict;
            try t.expect(input != copy);
            try expectKeys(copy, input.entries.keys());
            try t.expectEqual(shared.list.owned, copy.entries.get("first").?.list.owned);
        }
    }
}
