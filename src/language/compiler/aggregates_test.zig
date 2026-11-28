//! Tests of lists, records, path literals and slices.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Value = bc.Value;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const compile = compilation.compile;

test "list literals share assignments and explicit copies remain isolated across executions" {
    const Machine = @import("../Machine.zig");
    const input =
        \\fn collected() -> list
        \\    values:=[1,2]
        \\    for i in 3:40 do
        \\        values+=i
        \\    end
        \\    return values
        \\end
        \\seed:=[7]
        \\builder:=[];builder+=seed
        \\alias:=builder
        \\before:=[];before+=builder
        \\alias+=8
        \\after:=[];after+=builder
        \\count:=len(alias)
        \\result:=collected()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "list-builder.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            const seed = @import("../types.zig").sequence(machine.getGlobal("seed").?).?;
            const before = @import("../types.zig").sequence(machine.getGlobal("before").?).?;
            const after = @import("../types.zig").sequence(machine.getGlobal("after").?).?;
            const result = @import("../types.zig").sequence(machine.getGlobal("result").?).?;
            try std.testing.expectEqual(@as(usize, 1), seed.len);
            try std.testing.expectEqual(@as(usize, 1), before.len);
            try std.testing.expectEqual(@as(usize, 2), after.len);
            try std.testing.expectEqual(@as(i64, 8), after[1].int);
            try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("count").?.int);
            try std.testing.expectEqual(@as(usize, 40), result.len);
            try std.testing.expectEqual(@as(i64, 40), result[39].int);
        }
    }
    for ([_][]const u8{ "push([1],2)", "array([1])", "list(1)", "fn obsolete(value:array) end" }) |invalid| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, invalid, "invalid-list.huak", .{}, &diagnostic));
    }
}

test "list append assignment checks the target without declaring or rebinding it" {
    const invalid = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "missing+=1", .message = "unknown list variable" },
        .{ .input = "items:=1;items+=2", .message = "expected list" },
        .{ .input = "items:=\"a\";items+=\"b\"", .message = "expected list" },
        .{ .input = "param items=1;items+=2", .message = "readonly parameter" },
        .{ .input = "items:=[];value:=items+1", .message = "operator add" },
    };
    for ([_]bool{ false, true }) |optimize| {
        for (invalid) |case| {
            var diagnostic: ?Diagnostic = null;
            try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.input, "invalid-list-append.huak", .{ .optimize = optimize }, &diagnostic));
            try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), case.message) != null);
        }
    }
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\items:=[]
        \\items+=[1,2]
        \\fn extend(values:list, value:any)
        \\    values+=value
        \\    items+=value
        \\end
    , "list-append-bindings.huak", .{ .optimize = false }, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.global_names.len);
    const function = program.functions[1];
    try std.testing.expectEqual(@as(usize, 2), function.local_types.len);
    try std.testing.expectEqual(bc.Op.load_local, function.code[0].op);
    try std.testing.expectEqual(bc.Op.load_local, function.code[1].op);
    try std.testing.expectEqual(bc.Op.list_append, function.code[2].op);
    try std.testing.expectEqual(bc.Op.load_global, function.code[3].op);
    try std.testing.expectEqual(bc.Op.load_local, function.code[4].op);
    try std.testing.expectEqual(bc.Op.list_append, function.code[5].op);
    for (function.code) |instruction| try std.testing.expect(instruction.op != .store_local and instruction.op != .store_global);
}

fn listAllocationExercise(allocator: std.mem.Allocator, program: *const bc.Program) !void {
    const Machine = @import("../Machine.zig");
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
}

test "VM list builders release constructor growth and snapshot allocation failures" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\values:=[1,2]
        \\for i in 3:24 do; values+=i; end
        \\snapshot:=[];snapshot+=values
        \\values+=25
        \\count:=len(values)
    , "list-allocations.huak", .{}, &diagnostic);
    defer program.deinit();
    try listAllocationExercise(std.testing.allocator, &program);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), listAllocationExercise, .{&program});
}

fn aggregateGlobal(program: *const bc.Program, machine: *const @import("../Machine.zig"), name: []const u8) Value {
    for (program.global_names, machine.globals) |found, value| if (std.mem.eql(u8, found, name)) return value;
    unreachable;
}

test "aggregate compiler preserves nominal fields aliases and fresh defaults" {
    const input =
        \\struct Box
        \\ value:int=7
        \\ items:list=[]
        \\ options:dict={}
        \\end
        \\a:=Box(value:3)
        \\alias:=a
        \\alias.value=4
        \\a.items += 9
        \\a.options["key"]=12
        \\b:=Box()
        \\original:=a.value
        \\fresh:=len(b.items)+len(b.options)
        \\cloned:=copy(a)
        \\cloned.value=8
        \\independent:=a.value
        \\cloned.items[0]=10
        \\shared:=a.items[0]
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "aggregate.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 4), aggregateGlobal(&program, &machine, "original").int);
        try std.testing.expectEqual(@as(i64, 0), aggregateGlobal(&program, &machine, "fresh").int);
        try std.testing.expectEqual(@as(i64, 4), aggregateGlobal(&program, &machine, "independent").int);
        try std.testing.expectEqual(@as(i64, 10), aggregateGlobal(&program, &machine, "shared").int);
    }
}

test "aggregate compiler evaluates named arguments once in source order before defaults" {
    const input =
        \\events:=[0]
        \\fn event(value:int)->int
        \\ events[0]=events[0]*10+value
        \\ return value
        \\end
        \\struct Example
        \\ a:int
        \\ b:int
        \\ c:int=event(3)
        \\end
        \\fn combine(x:int=10,y:int=20,z:int=30)->int
        \\ return 100*x+10*y+z
        \\end
        \\object:=Example(b:event(1),a:event(2))
        \\result:=combine(y:event(4),x:event(5))
        \\trace:=events[0]
        \\fields:=object.a*100+object.b*10+object.c
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "aggregate-order.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 12345), aggregateGlobal(&program, &machine, "trace").int);
        try std.testing.expectEqual(@as(i64, 570), aggregateGlobal(&program, &machine, "result").int);
        try std.testing.expectEqual(@as(i64, 213), aggregateGlobal(&program, &machine, "fields").int);
    }
}

fn pathLiteralAllocationExercise(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(allocator,
            \\fn outline(a:vec2,b:vec2,c:vec2) -> path
            \\    return a~~b--c~~cycle
            \\end
            \\shape:=outline((0mm,0mm),(10mm,15mm),(20mm,0mm))
        , "path-allocation.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
    }
}

test "path literal lowering releases temporary and persistent data on every allocation failure" {
    try pathLiteralAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), pathLiteralAllocationExercise, .{});
}

test "slice operands retain for range order and distinguish omitted endpoints" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\calls:=[]
        \\fn record(value:int)->int calls+=value; return value end
        \\values:=[0,1,2,3]
        \\selected:=values[record(0):record(2):record(3)]
        \\tail:=selected[1:]
    , "slice-order.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const sequence = @import("../types.zig").sequence;
    const calls = sequence(machine.getGlobal("calls").?).?;
    try std.testing.expectEqual(@as(usize, 3), calls.len);
    for (calls, [_]i64{ 0, 3, 2 }) |item, expected| try std.testing.expectEqual(expected, item.int);
    const tail = sequence(machine.getGlobal("tail").?).?;
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqual(@as(i64, 2), tail[0].int);
    var count: usize = 0;
    for (program.functions[program.entry].code) |instruction| if (instruction.op == .slice) {
        try std.testing.expectEqual(@as(u32, @intFromBool(count == 1)), instruction.a);
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "an explicit dynamic void slice stop never becomes an open endpoint" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\fn missing()->any return end
            \\values:=[1,2,3]
            \\selected:=values[1:missing()]
        , "slice-void.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("../Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), "int") != null);
        try std.testing.expect(machine.getGlobal("selected") == null);
    }
}
