//! Tests of limits, native errors, source spans, panic, invalid bytecode and allocation failure.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Span = source.Span;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;
const TraceEntry = Machine.TraceEntry;

test "instruction and recursion limits report positioned call stacks" {
    const call_span: Span = .{ .start = 25, .end = 31 };
    var program = try testProgram(&.{.{ .name = "recurse", .code = &.{ .{ .op = .call, .a = 0, .span = call_span }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{ .call_depth = 8 });
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(@as(usize, 8), machine.failure.?.trace.len);
    try std.testing.expectEqual(call_span, machine.failure.?.diagnostic.span);
    try std.testing.expectEqualStrings("recurse", machine.failure.?.trace[0].function);
    program.functions = &.{.{ .name = "loop", .code = &.{ins(.jump, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    var loop = try Machine.init(std.testing.allocator, &program, .{}, .{ .instructions = 100 });
    defer loop.deinit();
    try std.testing.expectError(error.RuntimeFailed, loop.execute(&.{}));
    try std.testing.expectEqual(@as(u64, 100), loop.steps);
}

const FailingHost = struct {
    pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) anyerror!Value {
        return error.UpstreamDiagnostic;
    }
    fn message(_: ?*anyopaque) []const u8 {
        return "failed Typst layout: unknown variable α in content";
    }
};

test "native errors preserve the upstream diagnostic and source position" {
    const failure_span: Span = .{ .start = 42, .end = 55 };
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.constant, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.print), .b = 1, .span = failure_span }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .string = "x" }}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{ .vtable = &.{ .callBuiltin = FailingHost.call, .errorMessage = FailingHost.message } }, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(failure_span, machine.failure.?.diagnostic.span);
    try std.testing.expectEqualStrings(FailingHost.message(null), machine.failure.?.native_message);
}

test "compiled runtime failures report actual source spans and do not trap" {
    const compiler = @import("../compiler.zig");
    const cases = [_][]const u8{
        "x:=9223372036854775807+1\n",
        "x:=(-9223372036854775807-1)*(-1)\n",
        "x:=1/0\n",
        "x:=1e308*1e308\n",
        "x:=(-1)^0.5\n",
        "x:=[1][-1]\n",
        "for i in 0:0:1 do\nend\n",
    };
    for (cases) |input| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "failure.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(machine.failure.?.diagnostic.span.end > machine.failure.?.diagnostic.span.start);
        try std.testing.expect(machine.failure.?.trace.len > 0);
    }
}

test "panic is a host-independent failure with source and script call stack" {
    const HostProbe = struct {
        calls: usize = 0,

        fn call(context: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            const probe: *@This() = @ptrCast(@alignCast(context.?));
            probe.calls += 1;
            return error.UnexpectedHostCall;
        }
    };
    const script =
        \\fn stop(message:string) panic(message) end
        \\fn caller() stop("几何失败 Ω") end
        \\caller()
        \\after:=1
    ;
    var diagnostic: ?source.Diagnostic = null;
    var program = try @import("../compiler.zig").compile(std.testing.allocator, script, "panic.huak", .{}, &diagnostic);
    defer program.deinit();
    var probe: HostProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .callBuiltin = HostProbe.call } }, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    const detail = machine.failure.?;
    try std.testing.expectEqualStrings("panic", detail.text());
    try std.testing.expectEqualStrings("几何失败 Ω", detail.native_message);
    try std.testing.expectEqualStrings("panic.huak", detail.diagnostic.fileName().?);
    try std.testing.expectEqual(@as(usize, 1), detail.diagnostic.position(script).line);
    try std.testing.expectEqual(std.mem.indexOf(u8, script, "panic(message)").?, detail.diagnostic.span.start);
    try std.testing.expectEqual(@as(usize, 3), detail.trace.len);
    try std.testing.expectEqualStrings("stop", detail.trace[0].function);
    try std.testing.expectEqualStrings("caller", detail.trace[1].function);
    try std.testing.expect(machine.getGlobal("after") == null);
    const steps = machine.steps;
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(steps, machine.steps);
    try std.testing.expectEqualSlices(TraceEntry, detail.trace, machine.failure.?.trace);
    try std.testing.expect(builtin.lookup("assert") == null);
}

test "standard assert uses ordinary calls defaults and panic without a host" {
    const cases = [_]struct { call: []const u8, message: []const u8 }{
        .{ .call = "assert(false)", .message = "assertion failed" },
        .{ .call = "assert(false,\"自定义失败 Ω\")", .message = "自定义失败 Ω" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        const script = try std.fmt.allocPrint(
            std.testing.allocator,
            "import \"std/assertions.huak\".assert\nassert(true)\nassert(true,\"must not fail\")\n{s}\nafter:=42",
            .{case.call},
        );
        defer std.testing.allocator.free(script);
        var diagnostic: ?source.Diagnostic = null;
        var program = try @import("../compiler.zig").compile(std.testing.allocator, script, "assertion.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 2), program.modules.len);
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const detail = machine.failure.?;
        try std.testing.expectEqualStrings(case.message, detail.native_message);
        try std.testing.expectEqualStrings("std/assertions.huak", detail.diagnostic.fileName().?);
        try std.testing.expectEqualStrings("assert", detail.trace[0].function);
        try std.testing.expectEqual(@as(usize, 2), detail.trace.len);
        try std.testing.expectEqual(std.mem.indexOf(u8, script, case.call).?, detail.trace[1].span.start);
        try std.testing.expect(machine.getGlobal("after") == null);
    };
}

test "panic owns its complete long UTF8 message independently of program buffers" {
    const prefix = "数学诊断 Ω\n";
    const message = try std.testing.allocator.alloc(u8, prefix.len * 1024);
    defer std.testing.allocator.free(message);
    for (0..1024) |index| @memcpy(message[index * prefix.len ..][0..prefix.len], prefix);
    const expected = try std.testing.allocator.dupe(u8, message);
    defer std.testing.allocator.free(expected);
    var program = try testProgram(&.{.{
        .name = "script",
        .code = &.{ ins(.constant, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.panic), .b = 1 }, ins(.halt, 0) },
        .parameters = &.{},
        .result = .unit,
        .local_types = &.{},
    }}, &.{.{ .string = message }}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    @memset(message, 0);
    try std.testing.expectEqualStrings(expected, machine.failure.?.native_message);
    try std.testing.expect(std.unicode.utf8ValidateSlice(machine.failure.?.native_message));
}

fn panicAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = machine.execute(&.{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqualStrings("完整失败消息 Ω", machine.failure.?.native_message);
        return;
    };
    return error.ExpectedRuntimeFailure;
}

test "panic releases machine frames message and diagnostics at every allocation failure" {
    var diagnostic: ?source.Diagnostic = null;
    var program = try @import("../compiler.zig").compile(std.testing.allocator, "fn stop() panic(\"完整失败消息 Ω\") end; stop()", "panic-oom.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, panicAllocationExercise, .{&program});
}

test "invalid bytecode and uninitialized variables fail without accessing invalid memory" {
    const codes = [_][]const I{
        &.{ins(.pop, 0)},
        &.{ins(.constant, 100)},
        &.{ins(.jump, 100)},
        &.{ins(.load_global, 0)},
        &.{ins(.load_local, 0)},
        &.{.{ .op = .call, .a = 100 }},
        &.{ins(.make_list, 1)},
        &.{ins(.slice, 0)},
        &.{.{ .op = .call_builtin, .a = std.math.maxInt(u32) }},
    };
    for (codes) |code| {
        var program = try testProgram(&.{.{ .name = "script", .code = code, .parameters = &.{}, .result = .unit, .local_types = &.{.int} }}, &.{}, &.{"uninitialized"}, &.{.int});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
}

fn allocationExercise(allocator: std.mem.Allocator, fail_execution: bool) !void {
    const normal = [_]I{
        ins(.load_global, 0), ins(.constant, 0), ins(.add, 0), ins(.constant, 1), ins(.make_list, 2), ins(.constant, 2), ins(.index, 0), ins(.store_global, 1), ins(.halt, 0),
    };
    const failing = [_]I{ ins(.constant, 1), ins(.constant, 2), ins(.divide, 0), ins(.halt, 0) };
    var program: bytecode.Program = .{
        .arena = .init(allocator),
        .source_text = "allocation exercise",
        .name = "allocation.huak",
        .functions = &.{.{ .name = "script", .code = if (fail_execution) &failing else &normal, .parameters = &.{}, .result = .unit, .local_types = &.{ .any, .any } }},
        .constants = &.{ .{ .string = "完整输出" }, .{ .int = 2 }, .{ .int = 0 } },
        .parameters = &.{.{ .name = "prefix", .kind = .string, .default = null, .global = 0, .span = .{ .start = 0, .end = 1 } }},
        .global_names = &.{ "prefix", "result" },
        .global_types = &.{ .string, .string },
        .readonly_globals = &.{ true, false },
    };
    defer program.deinit();
    var machine = try Machine.init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = machine.execute(&.{.{ .name = "prefix", .value = "中文：" }}) catch |err| {
        if (err == error.RuntimeFailed and fail_execution) return;
        return err;
    };
    if (fail_execution) return error.ExpectedRuntimeFailure;
    try std.testing.expectEqualStrings("中文：完整输出", machine.getGlobal("result").?.string);
}

test "every allocation failure frees VM globals lists operands locals frames and diagnostics" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{true});
}
