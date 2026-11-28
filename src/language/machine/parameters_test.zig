//! Tests of script parameters, exports and concurrent runs of one program.
const std = @import("std");
const units = @import("../../drawing/units.zig");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const testing = @import("testing.zig");
const ins = testing.ins;
const testProgram = testing.testProgram;
const Override = Machine.Override;

test "dimensional bytecode parameters vectors and ratios retain native values" {
    const constants = [_]Value{
        .{ .quantity = try units.applyUnit(2, .cm) },
        .{ .quantity = try units.applyUnit(3, .mm) },
        .{ .int = 0 },
        .{ .string = "y" },
    };
    const instructions = [_]I{
        ins(.constant, 0),     ins(.constant, 1), ins(.add, 0),       ins(.store_global, 0),
        ins(.constant, 2),     ins(.constant, 0), ins(.make_vec2, 0), ins(.field, 3),
        ins(.store_global, 1), ins(.constant, 0), ins(.constant, 1),  ins(.divide, 0),
        ins(.store_global, 2), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &instructions, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "length", "coordinate", "ratio", "spin" }, &.{ .length, .length, .number, .angle });
    defer program.deinit();
    program.parameters = &.{.{ .name = "spin", .kind = .angle, .default = null, .global = 3, .span = .{ .start = 0, .end = 4 } }};
    program.readonly_globals = &.{ false, false, false, true };
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{.{ .name = "spin", .value = "2 pi rad" }});
    try std.testing.expectEqual(@as(f64, 23), machine.getGlobal("length").?.quantity.value);
    try std.testing.expectEqual(@as(f64, 20), machine.getGlobal("coordinate").?.quantity.value);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0 / 3.0), machine.getGlobal("ratio").?.number, 1e-12);
    try std.testing.expectEqual(try units.applyUnit(360, .deg), machine.getGlobal("spin").?.quantity);
    var wrong = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer wrong.deinit();
    try std.testing.expectError(error.RuntimeFailed, wrong.execute(&.{.{ .name = "spin", .value = "1cm" }}));
    try std.testing.expect(std.mem.find(u8, wrong.failure.?.diagnostic.text(), "angle") != null);
}

test "named exports read final bindings while ordinary assignments keep their values" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\export late
        \\export named:=4
        \\export saved:=named
        \\named=9
        \\late:=named+1
        \\alias:=named
        \\export alias
    , "export-values.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const expected_names = [_][]const u8{ "late", "named", "saved", "alias" };
    const expected_values = [_]i64{ 10, 9, 4, 9 };
    try std.testing.expectEqual(expected_names.len, program.exports.len);
    for (expected_names, expected_values, program.exports) |name, value, exported| {
        try std.testing.expectEqualStrings(name, exported.name);
        try std.testing.expectEqual(value, machine.getGlobal(program.global_names[exported.target.global]).?.int);
    }
}

test "exported values retain initialization when reassignment is not executed" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\export retained:=0
        \\if false then
        \\  retained=1%0
        \\end
        \\fn produced()->int; return 12; end
        \\export produced_value:=produced()
    , "retained-export.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("retained").?.int);
    try std.testing.expectEqual(@as(i64, 12), machine.getGlobal("produced_value").?.int);
}

test "inferred script parameters retain typed overrides and exported parameter values" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\param folder="."
        \\param count=3
        \\param scale=1.5
        \\param enabled=true
        \\export folder
        \\export count
        \\calculated:=count*scale
    , "inferred-overrides.huak", .{}, &diagnostic);
    defer program.deinit();
    var defaults = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer defaults.deinit();
    _ = try defaults.execute(&.{});
    try std.testing.expectEqualStrings(".", defaults.getGlobal("folder").?.string);
    try std.testing.expectEqual(@as(i64, 3), defaults.getGlobal("count").?.int);
    var overrides = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer overrides.deinit();
    _ = try overrides.execute(&.{ .{ .name = "folder", .value = "out dir" }, .{ .name = "count", .value = "7" }, .{ .name = "scale", .value = "2.5" }, .{ .name = "enabled", .value = "false" } });
    try std.testing.expectEqualStrings("out dir", overrides.getGlobal("folder").?.string);
    try std.testing.expectEqual(@as(i64, 7), overrides.getGlobal("count").?.int);
    try std.testing.expectEqual(@as(f64, 17.5), overrides.getGlobal("calculated").?.number);
    var invalid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{.{ .name = "count", .value = "7.5" }}));
    try std.testing.expectEqual(@as(u64, 0), invalid.steps);
}

test "one program can run with distinct readonly parameter values" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.load_global, 0), ins(.constant, 0), ins(.multiply, 0), ins(.store_global, 1), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .int = 2 }}, &.{ "count", "answer" }, &.{ .int, .int });
    defer program.deinit();
    program.parameters = &.{.{ .name = "count", .kind = .int, .default = .{ .int = 5 }, .global = 0, .span = .{ .start = 12, .end = 17 } }};
    const readonly = try program.arena.allocator().dupe(bool, &.{ true, false });
    program.readonly_globals = readonly;
    var first = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer first.deinit();
    try first.prepareParameters(&.{.{ .name = "count", .value = "7" }});
    try std.testing.expectEqual(@as(i64, 7), first.getGlobal("count").?.int);
    _ = try first.execute(&.{});
    var second = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer second.deinit();
    _ = try second.execute(&.{});
    try std.testing.expectEqual(@as(i64, 14), first.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(i64, 10), second.getGlobal("answer").?.int);
    try std.testing.expectError(error.RuntimeFailed, first.execute(&.{}));
}

test "parameters reject unknown duplicate missing and invalid values before execution" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{"count"}, &.{.int});
    defer program.deinit();
    program.parameters = &.{.{ .name = "count", .kind = .int, .default = null, .global = 0, .span = .{ .start = 8, .end = 13 } }};
    program.readonly_globals = &.{true};
    const cases = [_][]const Override{
        &.{.{ .name = "other", .value = "1" }},
        &.{ .{ .name = "count", .value = "1" }, .{ .name = "count", .value = "2" } },
        &.{},
        &.{.{ .name = "count", .value = "2.5" }},
    };
    for (cases) |overrides| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.prepareParameters(overrides));
        try std.testing.expectEqual(@as(u64, 0), machine.steps);
        try std.testing.expect(machine.failure != null);
    }
    program.functions = &.{.{ .name = "script", .code = &.{ ins(.constant, 0), ins(.store_global, 0), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    program.constants = &.{.{ .int = 3 }};
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{.{ .name = "count", .value = "1" }}));
    try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), "read-only") != null);
}

const ParallelRun = struct {
    program: *const bytecode.Program,
    parameter: []const u8,
    result: ?i64 = null,
    failed: bool = false,

    pub fn run(self: *ParallelRun) void {
        var machine = Machine.init(std.heap.page_allocator, self.program, .{}, .{}) catch {
            self.failed = true;
            return;
        };
        defer machine.deinit();
        _ = machine.execute(&.{.{ .name = "n", .value = self.parameter }}) catch {
            self.failed = true;
            return;
        };
        self.result = (machine.getGlobal("answer") orelse {
            self.failed = true;
            return;
        }).int;
    }
};

test "immutable bytecode can run concurrently with isolated parameters and globals" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, "param n:int=1; answer:=fact(n)\nfn fact(x:int)->int\nif x<=1 then;return 1;end\nreturn x*fact(x-1)\nend", "parallel.huak", .{}, &diagnostic);
    defer program.deinit();
    var contexts = [_]ParallelRun{
        .{ .program = &program, .parameter = "4" }, .{ .program = &program, .parameter = "5" },
        .{ .program = &program, .parameter = "6" }, .{ .program = &program, .parameter = "7" },
    };
    var threads: [contexts.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&contexts, &threads) |*context, *thread| {
        thread.* = try std.Thread.spawn(.{}, ParallelRun.run, .{context});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (contexts, [_]i64{ 24, 120, 720, 5040 }) |context, expected| {
        try std.testing.expect(!context.failed);
        try std.testing.expectEqual(@as(?i64, expected), context.result);
    }
}

test "string parameters validate UTF-8 before native host initialization" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, "param title:string=\"默认\"\n", "strings.huak", .{}, &diagnostic);
    defer program.deinit();
    var invalid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.prepareParameters(&.{.{ .name = "title", .value = "\xff" }}));
    try std.testing.expect(std.mem.find(u8, invalid.failure.?.text(), "UTF-8") != null);
    try std.testing.expectEqual(@as(u64, 0), invalid.steps);
    var valid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer valid.deinit();
    try valid.prepareParameters(&.{.{ .name = "title", .value = "中文 Ω" }});
    try std.testing.expectEqualStrings("中文 Ω", valid.getGlobal("title").?.string);
}
