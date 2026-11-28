//! Aggregate diagnostics and allocation failure.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");

test "aggregate diagnostics reject bad keys fields named arguments and native attribute writes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const invalid = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "data:={\"same\":1,\"\\u0073ame\":2}", .expected = "duplicate dictionary key" },
        .{ .text = "struct Data value:int end\nvalue:=Data(value:\"bad\")", .expected = "int" },
        .{ .text = "struct Data value:int end\nvalue:=Data(missing:1)", .expected = "unknown argument" },
        .{ .text = "value:=picture(640, 480)\nvalue.width=1", .expected = "writable field" },
        .{ .text = "data:={\"value\":1}\nresult:=data.value", .expected = "member" },
    };
    for ([_]bool{ false, true }) |optimize| {
        for (invalid) |case| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, harness.compile(t.allocator, &library, case.text, &.{}, optimize, &diagnostic));
            try t.expect(std.mem.find(u8, diagnostic.?.text(), case.expected) != null);
        }
        const failures = [_]struct { text: []const u8, expected: []const u8 }{
            .{ .text = "data:={}\nvalue:=data[\"absent\"]\nafter:=1", .expected = "has no key 'absent'" },
            .{ .text = "container:={\"value\":picture(640, 480)}\ncontainer[\"value\"].width=1\nafter:=1", .expected = "cannot assign field 'width'" },
            .{ .text = "container:=[(1,2)]\ncontainer[0].x=3\nafter:=1", .expected = "cannot assign field 'x'" },
            .{ .text = "fn read(value:any)->any return value[1] end\ndata:={}\nvalue:=read(data)\nafter:=1", .expected = "dictionary key must be string" },
            .{ .text = "struct Data value:int end\ncontainer:={\"value\":Data(1)}\ncontainer[\"value\"].value=\"bad\"\nafter:=1", .expected = "expected int, received string" },
        };
        for (failures) |case| {
            var program = try harness.compileValid(&library, case.text, &.{}, optimize);
            defer program.deinit();
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            const failure = machine.failure.?;
            try t.expect(std.mem.find(u8, failure.text(), case.expected) != null);
            try t.expect(machine.getGlobal("after") == null);
            try t.expect(failure.diagnostic.span.end > failure.diagnostic.span.start);
        }
    }
}

fn allocationScenario(allocator: std.mem.Allocator, library: *typst.Library) !void {
    var diagnostic: ?l.compiler.Diagnostic = null;
    var program = try harness.compile(allocator, library,
        \\struct Cell data:dict={"items":[]} end
        \\first:=Cell()
        \\first.data["items"]+=1
        \\second:=copy(first)
        \\second.data["items"]+=2
        \\data:={"first":first,"second":second}
        \\names:=data.keys()
        \\removed:=dict_remove(data,"first")
    , &.{}, true, &diagnostic);
    defer program.deinit();
    var runtime = try l.Runtime.init(allocator, allocator, library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try t.expect(machine.getGlobal("removed").?.boolean);
}

test "aggregate compilation and execution release every allocation on failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    try allocationScenario(t.allocator, &library);
    // Backing allocator resizes can change the number of later allocations.
    // Force the allocating fallback so each injected failure index is stable.
    var stable = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(stable.allocator(), allocationScenario, .{&library});
}
