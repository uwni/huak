//! Tests of locals, compiled control flow and dot calls.
const std = @import("std");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;

test "bytecode calls use separate locals and preserve recursive caller operands" {
    var program = try testProgram(&.{
        .{ .name = "script", .code = &.{ ins(.constant, 0), .{ .op = .call, .a = 1, .b = 1 }, ins(.store_global, 0), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "factorial", .code = &.{
            ins(.load_local, 0),   ins(.constant, 1),     ins(.less_equal, 0),              ins(.jump_if_false, 6),
            ins(.constant, 1),     ins(.return_value, 0), ins(.load_local, 0),              ins(.load_local, 0),
            ins(.constant, 1),     ins(.subtract, 0),     .{ .op = .call, .a = 1, .b = 1 }, ins(.multiply, 0),
            ins(.return_value, 0),
        }, .parameters = &.{.int}, .result = .int, .local_types = &.{.int} },
    }, &.{ .{ .int = 6 }, .{ .int = 1 } }, &.{"answer"}, &.{.int});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 720), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(usize, 0), machine.locals.items.len);
    try std.testing.expectEqual(@as(usize, 0), machine.frames.items.len);
}

test "compiler output runs recursive functions loops short circuits and zero based lists" {
    const compiler = @import("../compiler.zig");
    const input =
        \\param n:int=6
        \\answer:=fact(n)
        \\fn fact(x:int)->int
        \\    if x<=1 then
        \\        return 1
        \\    end
        \\    return x*fact(x-1)
        \\end
        \\total:=0
        \\for i in 1:10 do
        \\    if i==3 then; continue; end
        \\    if i==7 then; break; end
        \\    total=total+i
        \\    i=999
        \\end
        \\j:=0
        \\while j<3 do
        \\    j=j+1
        \\end
        \\skipped:=false and (1/0>0)
        \\taken:=true or (1/0>0)
        \\list:=[1,2,3]
        \\last:=list[2]
        \\point:=(2,3)*2
        \\px:=point.x
    ;
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, input, "control.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 720), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(i64, 18), machine.getGlobal("total").?.int);
    try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("j").?.int);
    try std.testing.expect(!machine.getGlobal("skipped").?.boolean);
    try std.testing.expect(machine.getGlobal("taken").?.boolean);
    try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("last").?.int);
    try std.testing.expectEqual(@as(f64, 4), machine.getGlobal("px").?.number);
}

test "inline then and do blocks match multiline execution with and without optimization" {
    const compiler = @import("../compiler.zig");
    const inline_source = "selected:=0; total:=0; for i in 1:3 do j:=0; while j<2 do j=j+1; if true then j:=99; j=100 end; if i==1 then total=total+1 elseif i==2 then total=total+10 else total=total+100 end end end; if false and (1/0>0) then selected=0 elseif true or (1/0>0) then selected=total+1 else selected=1%0 end";
    const multiline_source =
        \\selected:=0; total:=0
        \\for i in 1:3 do
        \\    j:=0
        \\    while j<2 do
        \\        j=j+1
        \\        if true then j:=99; j=100 end
        \\        if i==1 then
        \\            total=total+1
        \\        elseif i==2 then
        \\            total=total+10
        \\        else
        \\            total=total+100
        \\        end
        \\    end
        \\end
        \\if false and (1/0>0) then
        \\    selected=0
        \\elseif true or (1/0>0) then
        \\    selected=total+1
        \\else
        \\    selected=1%0
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        for ([_][]const u8{ inline_source, multiline_source }) |input| {
            var diagnostic: ?source.Diagnostic = null;
            var program = try compiler.compile(std.testing.allocator, input, "block-boundaries.huak", .{ .optimize = optimize }, &diagnostic);
            defer program.deinit();
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            try std.testing.expectEqual(@as(i64, 222), machine.getGlobal("total").?.int);
            try std.testing.expectEqual(@as(i64, 223), machine.getGlobal("selected").?.int);
            try std.testing.expect(machine.getGlobal("i") == null and machine.getGlobal("j") == null);
        }
    }
}

test "dot calls execute forward recursive chained indexed and expression receivers" {
    const compiler = @import("../compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\answer:=6.fact()
        \\chained:=(1+2).combine(4).combine(5)
        \\indexed:=[7,8][1].combine(9)
        \\point:=(2,3).move((4,5))
        \\property:=point.x
        \\called:=point.x()
        \\fn fact(x:int)->int
        \\  if x<=1 then; return 1; end
        \\  return x*(x-1).fact()
        \\end
        \\fn combine(x:int,y:int)->int; return x*10+y; end
        \\fn move(p:vec2,delta:vec2)->vec2; return p+delta; end
        \\fn x(p:vec2)->float; return p.y; end
    , "dot-execution.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 720), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(i64, 345), machine.getGlobal("chained").?.int);
    try std.testing.expectEqual(@as(i64, 89), machine.getGlobal("indexed").?.int);
    try std.testing.expectEqual(@as(f64, 6), machine.getGlobal("point").?.vec2.x);
    try std.testing.expectEqual(@as(f64, 8), machine.getGlobal("point").?.vec2.y);
    try std.testing.expectEqual(@as(f64, 6), machine.getGlobal("property").?.number);
    try std.testing.expectEqual(@as(f64, 8), machine.getGlobal("called").?.number);
}

test "dot calls evaluate the receiver once before arguments and use the builtin host" {
    const Log = struct {
        labels: [4][]const u8 = undefined,
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
        \\answer:=mark(2,"receiver").combine(mark(3,"first"),mark(4,"second"))
        \\caption:="unrelated data does not change receiver evaluation"
        \\"builtin".print()
        \\fn mark(value:int,label:string)->int
        \\  label.print()
        \\  return value
        \\end
        \\fn combine(x:int,y:int,z:int)->int; return x*100+y*10+z; end
    , "dot-evaluation.huak", .{}, &diagnostic);
    defer program.deinit();
    var log: Log = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &log, .vtable = &.{ .call_builtin = Log.print } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 234), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(usize, 4), log.count);
    for ([_][]const u8{ "receiver", "first", "second", "builtin" }, log.labels) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}
