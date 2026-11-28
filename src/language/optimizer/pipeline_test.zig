//! Tests of constant propagation through the optimizer pipeline of compile().
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Value = bc.Value;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const compile = compilation.compile;

test "constant propagation combines folding branch pruning and persistent globals" {
    const input =
        \\BASE:=2*3
        \\COUNT:=BASE+4
        \\result:=0
        \\if COUNT>8 then
        \\    result=COUNT*2
        \\else
        \\    dead:=9223372036854775807+1
        \\    panic("unreachable")
        \\    result=0
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-flow.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("BASE").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("COUNT").?.int);
        try std.testing.expectEqual(@as(i64, 20), machine.getGlobal("result").?.int);
        try std.testing.expect(machine.getGlobal("dead") == null);
        if (optimize) for (program.functions[program.entry].code) |instruction| switch (instruction.op) {
            .load_global, .add, .multiply, .greater, .jump_if_false, .call_builtin => return error.UnexpectedUnfoldedInstruction,
            else => {},
        };
    }
}

test "constant propagation joins only identical values and never assumes parameter defaults" {
    const input =
        \\param choose:bool=true
        \\same_value:=0
        \\dynamic:=0
        \\signed:=0.0
        \\if choose then same_value=12 else same_value=12 end
        \\same:=same_value+1
        \\if choose then dynamic=2; signed=-0.0 else dynamic=3; signed=0.0 end
        \\different:=dynamic+1
        \\copied:=signed
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-joins.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for ([_]bool{ false, true }) |choose| {
            var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "choose", .value = if (choose) "true" else "false" }});
            try std.testing.expectEqual(@as(i64, 13), machine.getGlobal("same").?.int);
            try std.testing.expectEqual(@as(i64, if (choose) 3 else 4), machine.getGlobal("different").?.int);
            try std.testing.expectEqual(@as(u64, if (choose) 0x8000000000000000 else 0), @as(u64, @bitCast(machine.getGlobal("copied").?.number)));
        }
        if (optimize) for (program.functions[program.entry].code, 0..) |instruction, index| {
            if (instruction.op != .store_global or !std.mem.eql(u8, program.global_names[instruction.a], "same")) continue;
            const preceding = program.functions[program.entry].code[index - 1];
            try std.testing.expectEqual(bc.Op.constant, preceding.op);
            try std.testing.expectEqual(@as(i64, 13), program.constants[preceding.a].int);
        };
    }
}

test "constant propagation retains loop updates and folds immutable loop inputs" {
    const input =
        \\param count:int=4
        \\FACTOR:=2*3
        \\total:=0
        \\for i in 1:count do total=total+FACTOR end
        \\result:=total
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-loop.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for ([_]struct { argument: []const u8, result: i64 }{ .{ .argument = "0", .result = 0 }, .{ .argument = "4", .result = 24 }, .{ .argument = "7", .result = 42 } }) |case| {
            var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "count", .value = case.argument }});
            try std.testing.expectEqual(case.result, machine.getGlobal("result").?.int);
        }
        if (optimize) for (program.functions[program.entry].code) |instruction| {
            if (instruction.op == .load_global and std.mem.eql(u8, program.global_names[instruction.a], "FACTOR")) return error.UnpropagatedLoopInvariant;
        };
    }
}

test "constant propagation respects typed stores and failed initialization" {
    const Machine = @import("../Machine.zig");
    const input =
        \\param choose:bool=false
        \\rounded:float:=9007199254740993
        \\result:=rounded+1
        \\distance:length:=1
        \\ratio:=distance/1pt
        \\fn local_rounding()->float
        \\    value:float:=9007199254740993
        \\    return value+1
        \\end
        \\local_result:=local_rounding()
        \\if not choose then after=late end
        \\late:=7
        \\after:=late
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-store-coercion.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for ([_]bool{ false, true }) |choose| {
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            if (choose) {
                _ = try machine.execute(&.{.{ .name = "choose", .value = "true" }});
                try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("after").?.int);
            } else {
                try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
                try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), "before initialization") != null);
                try std.testing.expect(machine.getGlobal("after") == null);
            }
            try std.testing.expectEqual(@as(f64, 9007199254740992), machine.getGlobal("result").?.number);
            try std.testing.expectEqual(@as(f64, 9007199254740992), machine.getGlobal("local_result").?.number);
            try std.testing.expectEqual(@as(f64, 1), machine.getGlobal("ratio").?.number);
        }
    }
}

test "constant propagation clears bindings at observable host calls" {
    const Machine = @import("../Machine.zig");
    const Observer = struct {
        machine: ?*Machine = null,
        calls: usize = 0,
        fn call(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, _: []const Value, _: ?*@import("../Machine.zig")) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print) return error.UnexpectedBuiltin;
            self.calls += 1;
            for (self.machine.?.program.global_names, 0..) |name, index| if (std.mem.eql(u8, name, "value")) {
                self.machine.?.globals[index] = .{ .int = 9 };
            };
            return .unit;
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, "value:=2; print(\"change\"); result:=value+1", "constant-host-barrier.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var observer: Observer = .{};
        var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &observer, .vtable = &.{ .callBuiltin = Observer.call } }, .{});
        defer machine.deinit();
        observer.machine = &machine;
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 1), observer.calls);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("result").?.int);
    }
}

fn propagationAllocationExercise(allocator: std.mem.Allocator) !void {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\FIRST:=2*3
        \\SECOND:=FIRST+4
        \\result:=0
        \\if SECOND>8 then result=SECOND*2 else panic("dead") end
    , "constant-flow-allocations.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try @import("../Machine.zig").init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 20), machine.getGlobal("result").?.int);
}

test "constant propagation pipeline releases every temporary round on allocation failure" {
    try propagationAllocationExercise(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), propagationAllocationExercise, .{});
}

test "constant propagation treats dynamic handle arithmetic as an implicit host barrier" {
    const Machine = @import("../Machine.zig");
    const Observer = struct {
        machine: ?*Machine = null,
        calls: usize = 0,
        fn path(_: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, _: []const Value, _: ?*@import("../Machine.zig")) !Value {
            if (id != .path) return error.UnexpectedBuiltin;
            return .{ .handle = .{ .kind = .path, .index = 0 } };
        }
        fn binary(context: ?*anyopaque, _: std.mem.Allocator, op: bc.Op, left: Value, right: Value) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (op != .add and op != .subtract) return error.UnexpectedOperator;
            if (op == .subtract) try std.testing.expect(left == .int and left.int == 0);
            try std.testing.expect(right.valueType() == .path);
            self.calls += 1;
            for (self.machine.?.program.global_names, 0..) |name, index| if (std.mem.eql(u8, name, "value")) {
                self.machine.?.globals[index] = .{ .int = 9 };
            };
            return .{ .int = 0 };
        }
    };
    for ([_]bool{ false, true }) |optimize| for ([_][]const u8{ "object+object", "-object" }) |operation| {
        const input = try std.testing.allocator.print("; object:any:=path((0,0),(1,1)); value:=2; ignored:={s}; result:=value+1", .{operation});
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-binary-barrier.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var observer: Observer = .{};
        var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &observer, .vtable = &.{ .callBuiltin = Observer.path, .binary = Observer.binary } }, .{});
        defer machine.deinit();
        observer.machine = &machine;
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 1), observer.calls);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("result").?.int);
    };
}
