//! Tests of constant folding and static branch pruning.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Value = bc.Value;
const types = @import("../types.zig");
const units = types.units;
const Instruction = bc.Instruction;
const Allocator = std.mem.Allocator;
const immutable = @import("value.zig");
const KeyContext = immutable.KeyContext;
const keyOf = immutable.keyOf;
const optimizer = @import("../optimizer.zig");

const TestResult = union(enum) { value: Value, failure: bc.source.Diagnostic };

fn runTest(code: []const Instruction, constants: []const Value, execution_limits: @import("../Machine.zig").Limits, host: @import("../Machine.zig").Host) !TestResult {
    const Machine = @import("../Machine.zig");
    var program: bc.Program = .{
        .arena = .init(std.testing.allocator),
        .source_text = "",
        .name = "optimizer-test.huak",
        .functions = &.{.{ .name = "<script>", .code = code, .parameters = &.{}, .result = .unit, .local_types = &.{} }},
        .constants = constants,
        .parameters = &.{},
        .global_names = &.{"result"},
        .global_types = &.{.any},
        .readonly_globals = &.{false},
    };
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, host, execution_limits);
    defer machine.deinit();
    _ = machine.execute(&.{}) catch |err| {
        if (err == error.RuntimeFailed) return .{ .failure = machine.failure.?.diagnostic };
        return err;
    };
    return .{ .value = machine.getGlobal("result") orelse .unit };
}

fn expectSame(before: []const Instruction, after: []const Instruction, constants: []const Value) !void {
    const original = try runTest(before, constants, .{}, .{});
    const optimized = try runTest(after, constants, .{}, .{});
    try std.testing.expectEqual(std.meta.activeTag(original), std.meta.activeTag(optimized));
    switch (original) {
        .value => |value| try std.testing.expectEqualDeep(value, optimized.value),
        .failure => |failure| {
            try std.testing.expectEqualStrings(failure.text(), optimized.failure.text());
            try std.testing.expectEqualDeep(failure.span, optimized.failure.span);
        },
    }
}

test "constant folding keeps exact integers floats booleans and error behavior" {
    const cases = [_]struct { left: Value, right: Value, op: bc.Op, folds: bool }{
        .{ .left = .{ .int = 20 }, .right = .{ .int = 22 }, .op = .add, .folds = true },
        .{ .left = .{ .int = 3 }, .right = .{ .int = 7 }, .op = .multiply, .folds = true },
        .{ .left = .{ .int = 1 }, .right = .{ .int = 4 }, .op = .divide, .folds = true },
        .{ .left = .{ .number = -0.0 }, .right = .{ .number = 0.0 }, .op = .subtract, .folds = true },
        .{ .left = .{ .int = 9007199254740993 }, .right = .{ .number = 9007199254740992.0 }, .op = .greater, .folds = true },
        .{ .left = .{ .int = 9007199254740993 }, .right = .{ .number = 9007199254740992.0 }, .op = .equal, .folds = true },
        .{ .left = .{ .boolean = true }, .right = .{ .boolean = false }, .op = .not_equal, .folds = true },
        .{ .left = .{ .int = std.math.maxInt(i64) }, .right = .{ .int = 1 }, .op = .add, .folds = false },
        .{ .left = .{ .int = std.math.minInt(i64) }, .right = .{ .int = -1 }, .op = .remainder, .folds = true },
        .{ .left = .{ .int = 1 }, .right = .{ .int = 0 }, .op = .divide, .folds = false },
        .{ .left = .{ .number = 1e308 }, .right = .{ .number = 2 }, .op = .multiply, .folds = false },
        .{ .left = .{ .number = -1 }, .right = .{ .number = 0.5 }, .op = .power, .folds = false },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pool: std.array_list.Managed(Value) = .init(arena.allocator());
        try pool.appendSlice(&.{ case.left, case.right });
        const code = [_]Instruction{
            .{ .op = .constant, .a = 0, .span = .{ .start = 1, .end = 2 } },
            .{ .op = .constant, .a = 1, .span = .{ .start = 3, .end = 4 } },
            .{ .op = case.op, .span = .{ .start = 1, .end = 4 } },
            .{ .op = .store_global, .a = 0 },
            .{ .op = .halt },
        };
        const result = try optimizer.optimize(arena.allocator(), &code, &pool, .{});
        try std.testing.expectEqual(@as(usize, if (case.folds) 3 else 5), result.len);
        try expectSame(&code, result, pool.items);
        if (case.folds and case.op == .subtract) {
            const bits: u64 = @bitCast((try runTest(result, pool.items, .{}, .{})).value.number);
            try std.testing.expectEqual(@as(u64, 1) << 63, bits);
        }
    }
}

test "quantity folding preserves dimensions errors and constant identities" {
    const cases = [_]struct { left: Value, right: Value, op: bc.Op, folds: bool }{
        .{ .left = .{ .quantity = try units.applyUnit(1, .cm) }, .right = .{ .quantity = try units.applyUnit(10, .mm) }, .op = .equal, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(2 * std.math.pi, .rad) }, .right = .{ .quantity = try units.applyUnit(360, .deg) }, .op = .equal, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(2, .cm) }, .right = .{ .quantity = try units.applyUnit(2, .mm) }, .op = .divide, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(2, .cm) }, .right = .{ .quantity = try units.applyUnit(2, .mm) }, .op = .multiply, .folds = true },
        .{ .left = .{ .int = 0 }, .right = .{ .quantity = try units.applyUnit(2, .cm) }, .op = .make_vec2, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(1, .cm) }, .right = .{ .quantity = try units.applyUnit(1, .deg) }, .op = .add, .folds = false },
        .{ .left = .{ .quantity = try units.applyUnit(1, .cm) }, .right = .{ .int = 0 }, .op = .divide, .folds = false },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pool: std.array_list.Managed(Value) = .init(arena.allocator());
        try pool.appendSlice(&.{ case.left, case.right });
        const code = [_]Instruction{
            .{ .op = .constant, .a = 0 },                          .{ .op = .constant, .a = 1 },
            .{ .op = case.op, .span = .{ .start = 3, .end = 7 } }, .{ .op = .store_global },
            .{ .op = .halt },
        };
        const optimized = try optimizer.optimize(arena.allocator(), &code, &pool, .{});
        try std.testing.expectEqual(@as(usize, if (case.folds) 3 else 5), optimized.len);
        try expectSame(&code, optimized, pool.items);
    }
    const magnitude: f64 = 1;
    const distance = keyOf(.{ .quantity = .{ .value = magnitude, .dimension = .distance } }).?;
    const rotation = keyOf(.{ .quantity = .{ .value = magnitude, .dimension = .rotation } }).?;
    try std.testing.expect(!KeyContext.eql(.{}, distance, rotation));
    const positive_zero = keyOf(.{ .quantity = .{ .value = 0.0, .dimension = .distance } }).?;
    const negative_zero = keyOf(.{ .quantity = .{ .value = -0.0, .dimension = .distance } }).?;
    try std.testing.expect(!KeyContext.eql(.{}, positive_zero, negative_zero));
}

test "static branch pruning retains host effects only on reachable paths" {
    const Log = struct {
        calls: usize = 0,
        fn call(context: ?*anyopaque, _: Allocator, _: @import("../builtin.zig").Id, _: []const Value, _: ?*@import("../Machine.zig")) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .unit;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.appendSlice(&.{ .{ .boolean = false }, .{ .int = 10 }, .{ .int = 32 } });
    const code = [_]Instruction{
        .{ .op = .constant, .a = 0 },
        .{ .op = .jump_if_false, .a = 5 },
        .{ .op = .constant, .a = 1 },
        .{ .op = .call_builtin, .a = @backingInt(@import("../builtin.zig").Id.print), .b = 1 },
        .{ .op = .pop },
        .{ .op = .constant, .a = 1 },
        .{ .op = .call_builtin, .a = @backingInt(@import("../builtin.zig").Id.print), .b = 1 },
        .{ .op = .pop },
        .{ .op = .constant, .a = 1 },
        .{ .op = .constant, .a = 2 },
        .{ .op = .add },
        .{ .op = .store_global, .a = 0 },
        .{ .op = .halt },
    };
    const result = try optimizer.optimize(arena.allocator(), &code, &pool, .{});
    try std.testing.expect(result.len < code.len);
    var before: Log = .{};
    var after: Log = .{};
    const original = try runTest(&code, pool.items, .{}, .{ .ptr = &before, .vtable = &.{ .callBuiltin = Log.call } });
    const optimized = try runTest(result, pool.items, .{}, .{ .ptr = &after, .vtable = &.{ .callBuiltin = Log.call } });
    try std.testing.expectEqual(@as(usize, 1), before.calls);
    try std.testing.expectEqual(before.calls, after.calls);
    try std.testing.expectEqualDeep(original.value, optimized.value);
}

test "jump targets form barriers and optimized back edges retain instruction limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.append(.{ .int = 1 });
    // The jump enters at the second constant. Folding across that entry would
    // turn a runtime stack error into a successful computation.
    const incoming = [_]Instruction{
        .{ .op = .jump, .a = 2 },                           .{ .op = .constant },     .{ .op = .constant },
        .{ .op = .add, .span = .{ .start = 8, .end = 9 } }, .{ .op = .store_global }, .{ .op = .halt },
    };
    try expectSame(&incoming, try optimizer.optimize(arena.allocator(), &incoming, &pool, .{}), pool.items);
    const loop = [_]Instruction{
        .{ .op = .constant }, .{ .op = .pop }, .{ .op = .jump, .a = 0 },
    };
    const optimized = try optimizer.optimize(arena.allocator(), &loop, &pool, .{});
    try std.testing.expectEqual(@as(usize, 1), optimized.len);
    try std.testing.expectEqual(bc.Op.jump, optimized[0].op);
    const stopped = try runTest(optimized, pool.items, .{ .instructions = 10 }, .{});
    try std.testing.expect(stopped == .failure);
    try std.testing.expect(std.mem.indexOf(u8, stopped.failure.text(), "instruction limit") != null);
}

test "unary errors and invalid constants remain runtime checks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.appendSlice(&.{ .{ .int = std.math.minInt(i64) }, .{ .number = std.math.inf(f64) }, .{ .boolean = false } });
    const overflow = [_]Instruction{ .{ .op = .constant }, .{ .op = .negate }, .{ .op = .store_global }, .{ .op = .halt } };
    try expectSame(&overflow, try optimizer.optimize(arena.allocator(), &overflow, &pool, .{}), pool.items);
    const nonfinite = [_]Instruction{ .{ .op = .constant, .a = 1 }, .{ .op = .pop }, .{ .op = .halt } };
    try expectSame(&nonfinite, try optimizer.optimize(arena.allocator(), &nonfinite, &pool, .{}), pool.items);
    const invalid = [_]Instruction{ .{ .op = .constant, .a = 2 }, .{ .op = .negate }, .{ .op = .pop }, .{ .op = .halt } };
    try expectSame(&invalid, try optimizer.optimize(arena.allocator(), &invalid, &pool, .{}), pool.items);
}

test "short circuit branch patterns and forward jump chains preserve boolean values" {
    for ([_]bool{ false, true }) |initial| {
        for ([_]bool{ false, true }) |is_or| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var pool: std.array_list.Managed(Value) = .init(arena.allocator());
            try pool.appendSlice(&.{ .{ .boolean = initial }, .{ .boolean = true } });
            var code: std.array_list.Managed(Instruction) = .init(arena.allocator());
            try code.appendSlice(&.{ .{ .op = .constant }, .{ .op = .duplicate } });
            if (is_or) try code.append(.{ .op = .logical_not });
            const branch = code.items.len;
            try code.appendSlice(&.{ .{ .op = .jump_if_false }, .{ .op = .pop }, .{ .op = .constant, .a = 1 } });
            code.items[branch].a = @intCast(code.items.len);
            const jump = code.items.len;
            try code.append(.{ .op = .jump, .a = @intCast(jump + 1) });
            try code.append(.{ .op = .jump, .a = @intCast(jump + 2) });
            try code.appendSlice(&.{ .{ .op = .store_global }, .{ .op = .halt } });
            try expectSame(code.items, try optimizer.optimize(arena.allocator(), code.items, &pool, .{}), pool.items);
        }
    }
}

test "deterministic finite expression samples execute identically after folding" {
    var generator = std.Random.DefaultPrng.init(0x4855414b);
    const random = generator.random();
    for (0..64) |_| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pool: std.array_list.Managed(Value) = .init(arena.allocator());
        for (0..3) |_| try pool.append(.{ .int = random.intRangeAtMost(i64, -100, 100) });
        const code = [_]Instruction{
            .{ .op = .constant },         .{ .op = .constant, .a = 1 }, .{ .op = .subtract },
            .{ .op = .constant, .a = 2 }, .{ .op = .multiply },         .{ .op = .negate },
            .{ .op = .store_global },     .{ .op = .halt },
        };
        const result = try optimizer.optimize(arena.allocator(), &code, &pool, .{});
        try std.testing.expectEqual(@as(usize, 3), result.len);
        try expectSame(&code, result, pool.items);
    }
}

test "pruning exposes another folding round before pipeline convergence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.appendSlice(&.{ .{ .int = 2 }, .{ .int = 3 }, .{ .int = 999 } });
    const input = [_]Instruction{
        .{ .op = .constant, .a = 0 },
        .{ .op = .jump, .a = 3 },
        .{ .op = .constant, .a = 2 },
        .{ .op = .constant, .a = 1 },
        .{ .op = .add },
        .{ .op = .store_global },
        .{ .op = .halt },
    };
    const output = try optimizer.optimize(arena.allocator(), &input, &pool, .{ .global_types = &.{.any} });
    try expectSame(&input, output, pool.items);
    for (output) |instruction| if (instruction.op == .add or instruction.op == .jump) return error.UnstableOptimizationPipeline;
    const again = try optimizer.optimize(arena.allocator(), output, &pool, .{ .global_types = &.{.any} });
    try std.testing.expect(optimizer.sameCode(output, again));
}
