//! Tests of numeric ranges.
const std = @import("std");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const iteration = @import("iteration.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;

test "dimensionless quantity inputs normalize safely in ranges" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const normalized = try iteration.initializeRange(&machine, .{ .quantity = .{ .value = 0 } }, .{ .int = 2 }, .{ .int = 1 });
    try std.testing.expectEqual(@as(f64, 0), normalized[0].number);
    try std.testing.expectEqual(@as(f64, 1), normalized[2].number);
    try std.testing.expect(try iteration.rangeTest(&machine, normalized[0], normalized[1], normalized[2]));
}

test "range progression terminates after representable endpoints without overflow" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const max: Value = .{ .int = std.math.maxInt(i64) };
    const min: Value = .{ .int = std.math.minInt(i64) };
    try std.testing.expect(!(try iteration.rangeAdvance(&machine, max, max, .{ .int = 1 })).more);
    try std.testing.expect(!(try iteration.rangeAdvance(&machine, .{ .int = std.math.maxInt(i64) - 1 }, max, .{ .int = 2 })).more);
    try std.testing.expect(!(try iteration.rangeAdvance(&machine, .{ .int = std.math.minInt(i64) + 1 }, min, .{ .int = -2 })).more);
    try std.testing.expectEqual(@as(i64, 2), (try iteration.rangeAdvance(&machine, .{ .int = 3 }, .{ .int = 0 }, .{ .int = -1 })).value.int);
    try std.testing.expectError(error.RuntimeFailed, iteration.rangeTest(&machine, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 0 }));
}

test "compiled ranges include endpoints descending steps and safe integer overshoot" {
    const compiler = @import("../compiler.zig");
    const input =
        \\up:=0
        \\for i in 0:2:4 do
        \\up=up+i
        \\end
        \\down:=0
        \\for i in 3:-1:0 do
        \\down=down+i
        \\end
        \\edge:=0
        \\for i in 9223372036854775806:2:9223372036854775807 do
        \\edge=edge+1
        \\end
        \\empty:=0
        \\for i in 3:1 do
        \\empty=empty+1
        \\end
    ;
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, input, "range.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("up").?.int);
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("down").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("edge").?.int);
    try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("empty").?.int);
}

test "dynamic integer ranges preserve precision endpoints and independent iteration state" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\bounds:=[1,3]
        \\sum:=0
        \\for i in bounds[0]:bounds[1] do; sum=sum+i; end
        \\large:=[9007199254740993,9007199254740993]
        \\visits:=0
        \\observed:=[]; for exact in large[0]:large[1] do; observed+=exact; visits=visits+1; end
        \\hi:=[9223372036854775806,9223372036854775807]
        \\hi_count:=0
        \\for hi_value in hi[0]:2:hi[1] do; hi_count=hi_count+1; end
        \\for hi_endpoint in hi[1]:hi[1] do; observed+=hi_endpoint; visits=visits+1; end
        \\lo:=[-9223372036854775807,-9223372036854775808]
        \\lo_count:=0
        \\for lo_value in lo[0]:-2:lo[1] do; lo_count=lo_count+1; end
        \\for lo_endpoint in lo[1]:-1:lo[1] do; observed+=lo_endpoint; visits=visits+1; end
        \\selected:=0
        \\for changed in bounds[0]:5 do
        \\    saved:=changed
        \\    changed=100
        \\    if saved==2 then; continue; end
        \\    selected=selected+saved
        \\    if saved==4 then; break; end
        \\end
    , "dynamic-integer-ranges.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("sum").?.int);
    try std.testing.expectEqual(@as(i64, 9007199254740993), types.sequence(machine.getGlobal("observed").?).?[0].int);
    try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("visits").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("hi_count").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("lo_count").?.int);
    try std.testing.expectEqual(std.math.maxInt(i64), types.sequence(machine.getGlobal("observed").?).?[1].int);
    try std.testing.expectEqual(std.math.minInt(i64), types.sequence(machine.getGlobal("observed").?).?[2].int);
    try std.testing.expectEqual(@as(i64, 8), machine.getGlobal("selected").?.int);
    try std.testing.expect(machine.getGlobal("changed") == null);
}

test "one compiled dynamic range normalizes actual types separately for each execution" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\param floating:bool=false
        \\bounds:=[1,3,1]
        \\if floating then; bounds=[1,3.0,1]; end
        \\result:=collect(bounds[0],bounds[1],bounds[2])
        \\from_start:=collect([1.0][0],3,1)
        \\from_step:=collect(1,2,[0.5][0])
        \\fn collect(start:any,stop:any,step:any)->list
        \\    count:=0
        \\    first:any:=0
        \\    last:any:=0
        \\    for i in start:step:stop do
        \\        if count==0 then; first=i; end
        \\        last=i
        \\        count=count+1
        \\    end
        \\    return [first,last,count]
        \\end
    , "reusable-dynamic-range.huak", .{}, &diagnostic);
    defer program.deinit();
    for ([_]bool{ false, true }) |floating| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{.{ .name = "floating", .value = if (floating) "true" else "false" }});
        const result = types.sequence(machine.getGlobal("result").?).?;
        try std.testing.expectEqual(@as(i64, 3), result[2].int);
        if (floating) {
            try std.testing.expectEqual(@as(f64, 1), result[0].number);
            try std.testing.expectEqual(@as(f64, 3), result[1].number);
        } else {
            try std.testing.expectEqual(@as(i64, 1), result[0].int);
            try std.testing.expectEqual(@as(i64, 3), result[1].int);
        }
        const from_start = types.sequence(machine.getGlobal("from_start").?).?;
        try std.testing.expectEqual(@as(f64, 1), from_start[0].number);
        try std.testing.expectEqual(@as(f64, 3), from_start[1].number);
        const from_step = types.sequence(machine.getGlobal("from_step").?).?;
        try std.testing.expectEqual(@as(f64, 1), from_step[0].number);
        try std.testing.expectEqual(@as(f64, 2), from_step[1].number);
        try std.testing.expectEqual(@as(i64, 3), from_step[2].int);
    }
}

test "floating bounds normalize the first value and loop variables shadow outer bindings" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\observed:=[]; for dynamic_start in [1.0][0]:3 do; observed+=dynamic_start; break; end
        \\for dynamic_stop in 1:[3.0][0] do; observed+=dynamic_stop; break; end
        \\for dynamic_step in 1:[0.5][0]:2 do; observed+=dynamic_step; break; end
        \\for static_float in 1:0.5:2 do; observed+=static_float; break; end
        \\typed:float:=0
        \\for typed in 1:3 do; break; end
        \\down:=0
        \\for descending in [3][0]:[-1][0]:[1][0] do; down=down+descending; end
        \\empty:=0
        \\for none in [3][0]:[1][0] do; empty=empty+1; end
    , "floating-range.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    for (types.sequence(machine.getGlobal("observed").?).?) |value| {
        try std.testing.expectEqual(@as(f64, 1), value.number);
    }
    try std.testing.expectEqual(@as(f64, 0), machine.getGlobal("typed").?.number);
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("down").?.int);
    try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("empty").?.int);
    try std.testing.expect(machine.getGlobal("none") == null);
}

test "range operands are evaluated once before normalization in their existing order" {
    const Log = struct {
        labels: [3][]const u8 = undefined,
        count: usize = 0,

        fn print(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print or self.count == self.labels.len) return error.UnexpectedCall;
            self.labels[self.count] = args[0].string;
            self.count += 1;
            return .unit;
        }
    };
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\sum:=0
        \\for i in bound(1,"start"):bound(1,"step"):bound(3,"stop") do; sum=sum+i; end
        \\fn bound(value:any,label:string)->any
        \\    print(label)
        \\    return value
        \\end
    , "range-evaluation.huak", .{}, &diagnostic);
    defer program.deinit();
    var log: Log = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &log, .vtable = &.{ .callBuiltin = Log.print } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(usize, 3), log.count);
    try std.testing.expectEqualStrings("start", log.labels[0]);
    try std.testing.expectEqualStrings("stop", log.labels[1]);
    try std.testing.expectEqualStrings("step", log.labels[2]);
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("sum").?.int);
}

test "range initialization validates every operand even before an empty range" {
    const compiler = @import("../compiler.zig");
    const cases = [_]struct { values: []const u8, message: []const u8 }{
        .{ .values = "[true,1,1]", .message = "expected a number" },
        .{ .values = "[3,\"stop\",1]", .message = "expected a number" },
        .{ .values = "[3,1,false]", .message = "expected a number" },
        .{ .values = "[3,1,0]", .message = "range step must not be zero" },
        .{ .values = "[3,1,-0.0]", .message = "range step must not be zero" },
        .{ .values = "[9223372036854775807,9223372036854775807,0]", .message = "range step must not be zero" },
        .{ .values = "[-9223372036854775808,-9223372036854775808,0]", .message = "range step must not be zero" },
    };
    for (cases) |case| {
        const input = try std.testing.allocator.print("values:={s}\nentered:=false\nfor i in values[0]:values[2]:values[1] do; entered=true; end\n", .{case.values});
        defer std.testing.allocator.free(input);
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "invalid-range.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), case.message) != null);
        try std.testing.expect(!machine.getGlobal("entered").?.boolean);
        try std.testing.expect(machine.getGlobal("i") == null);
    }
    // Non-finite data can arrive through an external host's dynamic values.
    // Test every position directly; source literals already reject these.
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |nonfinite| {
        for (0..3) |position| {
            var program = try testProgram(&.{}, &.{}, &.{}, &.{});
            defer program.deinit();
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            var operands = [_]Value{ .{ .int = 3 }, .{ .int = 1 }, .{ .int = 1 } };
            operands[position] = .{ .number = nonfinite };
            try std.testing.expectError(error.RuntimeFailed, iteration.initializeRange(&machine, operands[0], operands[1], operands[2]));
            try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), "finite") != null);
        }
    }
}
