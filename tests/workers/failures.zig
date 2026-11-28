//! Worker failures: earlier errors and successful prefixes, diagnostics, instruction budgets and uninitialized future globals.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");

const Failure = struct {
    span: l.bytecode.Span,
    message: []u8,
    native_message: []u8,
    first_initialized: bool,
    second_initialized: bool,
    third_initialized: bool,
    steps: u64,

    fn deinit(self: *Failure) void {
        t.allocator.free(self.message);
        t.allocator.free(self.native_message);
    }
};

fn failing(library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, limits: l.Machine.Limits) !Failure {
    return failingOptions(library, program, jobs, limits, .{});
}

fn failingOptions(library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, limits: l.Machine.Limits, runtime_options: l.Runtime.Options) !Failure {
    var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = library, .workers = .init(t.io, jobs) }, runtime_options);
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, program, runtime.host(), limits);
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
    executor.attach(&machine);
    try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
    const detail = machine.failure orelse return error.MissingExpectedDiagnostic;
    const message = try t.allocator.dupe(u8, detail.text());
    errdefer t.allocator.free(message);
    return .{
        .span = detail.diagnostic.span,
        .message = message,
        .native_message = try t.allocator.dupe(u8, detail.native_message),
        .first_initialized = machine.getGlobal("first") != null,
        .second_initialized = machine.getGlobal("second") != null,
        .third_initialized = machine.getGlobal("third") != null,
        .steps = machine.steps,
    };
}

test "speculative typography preparation preserves earlier errors and successful prefixes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const builders =
        \\import paint.{draw, label, picture};fn early(divisor:int) -> picture
        \\ p:=picture(100,80)
        \\ y:=10/divisor
        \\ object.append(p, object.draw((0,0)--(50,y*1.0)))
        \\ return p
        \\end
        \\fn late() -> picture
        \\ p:=picture(100,80)
        \\ object.append(p, object.label(typ[Late text], (5,30)))
        \\ return p
        \\end
        \\
    ;
    for ([_]i64{ 0, 1 }) |divisor| {
        const source = try t.allocator.print("{s}first:=early({d})\nsecond:=late()\n", .{ builders, divisor });
        defer t.allocator.free(source);
        var program = try harness.compile(&library, source, true);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        const runtime_options: l.Runtime.Options = .{ .font_sources = &.{.{ .data = "invalid font bytes" }} };
        var serial = try failingOptions(&library, &program, 1, .{}, runtime_options);
        defer serial.deinit();
        var parallel = try failingOptions(&library, &program, 4, .{}, runtime_options);
        defer parallel.deinit();
        try expectSameFailure(serial, parallel);
        try t.expectEqual(divisor != 0, parallel.first_initialized);
    }
}

fn expectSameFailure(expected: Failure, actual: Failure) !void {
    try t.expectEqualDeep(expected.span, actual.span);
    try t.expectEqualSlices(u8, expected.message, actual.message);
    try t.expectEqualSlices(u8, expected.native_message, actual.native_message);
    try t.expectEqual(expected.first_initialized, actual.first_initialized);
    try t.expectEqual(expected.second_initialized, actual.second_initialized);
    try t.expectEqual(expected.third_initialized, actual.third_initialized);
    try t.expectEqual(expected.steps, actual.steps);
}

test "worker failures publish the same successful prefix and first source diagnostic" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{draw, picture};import assertions.assert
        \\fn figure(index:int) -> picture
        \\ p := picture(100,80)
        \\ for stroke in 0:80 do
        \\  object.append(p, object.draw((0,stroke)--(90,stroke)))
        \\ end
        \\ assert(index != 2)
        \\ return p
        \\end
        \\first := figure(1)
        \\second := figure(2)
        \\third := figure(2)
    , true);
    defer program.deinit();
    var serial = try failing(&library, &program, 1, .{});
    defer serial.deinit();
    try t.expect(serial.first_initialized);
    try t.expect(!serial.second_initialized);
    try t.expect(!serial.third_initialized);
    for ([_]usize{ 2, 4 }) |jobs| {
        var parallel = try failing(&library, &program, jobs, .{});
        defer parallel.deinit();
        try expectSameFailure(serial, parallel);
    }
}

test "native worker diagnostics survive temporary layout and task arenas" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{label, picture};fn good() -> picture
        \\ p := picture(100,80)
        \\ object.append(p, object.label(typ[Good Ω], (5,25)))
        \\ return p
        \\end
        \\fn broken() -> picture
        \\ p := picture(100,80)
        \\ object.append(p, object.label(typ[#unknown_worker_symbol], (5,25)))
        \\ return p
        \\end
        \\first := good()
        \\second := broken()
        \\third := broken()
    , true);
    defer program.deinit();
    var serial = try failing(&library, &program, 1, .{});
    defer serial.deinit();
    var parallel = try failing(&library, &program, 4, .{});
    defer parallel.deinit();
    try expectSameFailure(serial, parallel);
    try t.expect(std.mem.find(u8, parallel.native_message, "unknown_worker_symbol") != null);
}

test "instruction budgets preserve serial source locations and initialized bindings" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library, harness.drawing ++
        \\first := figure(1)
        \\second := figure(2)
        \\third := figure(3)
    , true);
    defer program.deinit();
    for ([_]u64{ 20, 100, 1000, 10000 }) |budget| {
        var serial = try failing(&library, &program, 1, .{ .instructions = budget });
        defer serial.deinit();
        var parallel = try failing(&library, &program, 4, .{ .instructions = budget });
        defer parallel.deinit();
        try expectSameFailure(serial, parallel);
    }
}

test "future globals remain uninitialized reads instead of introducing future writer dependencies" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{draw, picture, append};fn reader() -> picture
        \\ p := picture(100,80)
        \\ p.append(copy(third))
        \\ return p
        \\end
        \\fn fresh() -> picture
        \\ p := picture(100,80)
        \\ object.append(p, object.draw((0,0)--(90,70)))
        \\ return p
        \\end
        \\first := reader()
        \\second := fresh()
        \\third := fresh()
    , true);
    defer program.deinit();
    var serial = try failing(&library, &program, 1, .{});
    defer serial.deinit();
    var parallel = try failing(&library, &program, 4, .{});
    defer parallel.deinit();
    try expectSameFailure(serial, parallel);
    try t.expect(!parallel.first_initialized);
    try t.expect(!parallel.third_initialized);
}
