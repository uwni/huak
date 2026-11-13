//! Public math namespace contracts through source, optimization and execution.
const std = @import("std");
const t = std.testing;
const l = @import("huak").language;
const typst = @import("libtypst");
const options = @import("test_options");

fn compile(source: []const u8, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "math.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
        return err;
    };
}

fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("{s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

test "random streams replay across seeds optimizations and independent executions" {
    const source =
        \\import math.{seed, random as uniform, randint, randn}
        \\initial:=math.random()
        \\seed(-42)
        \\first:=[uniform(),randint(min:-9,max:9),randn()]
        \\seed(-42)
        \\again:=[uniform(),randint(max:9,min:-9),randn()]
        \\singleton:=randint(7,7)
        \\wide:=randint(-9223372036854775807-1,9223372036854775807)
        \\samples:=[]
        \\for i in 0:511 do samples += [uniform(),randint(-9,9),randn()] end
    ;
    var reference: ?[4]l.types.Value = null;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(source, optimize);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try l.Machine.init(t.allocator, &program, .{}, .{});
            defer machine.deinit();
            try execute(&machine);
            const first = machine.getGlobal("first").?.list.items();
            try t.expectEqualDeep(first, machine.getGlobal("again").?.list.items());
            const observed = [4]l.types.Value{ machine.getGlobal("initial").?, first[0], first[1], first[2] };
            if (reference) |previous| try t.expectEqualDeep(previous, observed) else reference = observed;
            try t.expectEqual(@as(i64, 7), machine.getGlobal("singleton").?.int);
            const samples = machine.getGlobal("samples").?.list.items();
            try t.expectEqual(@as(usize, 1536), samples.len);
            var sum: f64 = 0;
            var squares: f64 = 0;
            var distinct = false;
            for (0..512) |i| {
                const u = samples[i * 3].number;
                const integer = samples[i * 3 + 1].int;
                const normal = samples[i * 3 + 2].number;
                try t.expect(u >= 0 and u < 1);
                try t.expect(integer >= -9 and integer <= 9);
                try t.expect(std.math.isFinite(normal));
                distinct = distinct or u != samples[0].number;
                sum += normal;
                squares += normal * normal;
            }
            try t.expect(distinct);
            try t.expect(@abs(sum / 512) < 0.2);
            try t.expect(squares / 512 > 0.7 and squares / 512 < 1.3);
        }
    }
}

test "logarithms use dimensionless positive inputs through the public namespace" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile("import math.{log as ln,log10}\nvalues:=[ln(1),ln(2),log10(value:1000),log10(1e-100)]", optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const expected = [_]f64{ 0, @log(@as(f64, 2)), 3, -100 };
        for (expected, machine.getGlobal("values").?.list.items()) |want, actual|
            try t.expectApproxEqAbs(want, actual.number, 1e-13);
        try t.expect(runtime.engine == null);
    }
    for ([_][]const u8{ "math.log(0)", "math.log(-1)", "math.log10(0)", "math.log10(-2)" }) |source| {
        var program = try compile(source, true);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
}

test "round takes halves away from zero without floor's offset error" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile("import math.{round, floor}\nnear_half:=0.49999999999999994\nvalues:=[round(2.5),round(-2.5),round(value:1.4),math.round(-0.4),round(near_half),floor(near_half+0.5)]", optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        // floor(x+0.5) rounds the largest double below 0.5 up to 1.
        const expected = [_]f64{ 3, -3, 1, 0, 0, 1 };
        for (expected, machine.getGlobal("values").?.list.items()) |want, actual|
            try t.expectEqual(want, actual.number);
    }
}

test "special functions accept aliases named arguments and finite tail values" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import std.math.{gamma as G, lgamma, beta, erf, erfc}
        \\values:=[G(value:5),G(0.5),G(-0.5),lgamma(-0.5),beta(b:3,a:2),erf(-1),erfc(10)]
    ;
    const expected = [_]f64{ 24, @sqrt(std.math.pi), -2 * @sqrt(std.math.pi), @log(2 * @sqrt(std.math.pi)), 1.0 / 12.0, -0.84270079294971486934, 2.0884875837625447570e-45 };
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(source, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for (expected, machine.getGlobal("values").?.list.items()) |want, actual|
            try t.expectApproxEqRel(want, actual.number, 3e-14);
        try t.expect(runtime.engine == null);
    }
}

test "each random operation prevents speculative worker execution through helpers" {
    for ([_][]const u8{ "math.seed(42)", "math.random()", "math.randint(-5,5)", "math.randn()" }) |call| {
        const source = try std.fmt.allocPrint(t.allocator,
            \\fn effect() -> void
            \\    {s}
            \\end
            \\fn figure() -> picture
            \\    effect()
            \\    return picture(10,10)
            \\end
            \\export first:=figure()
            \\export second:=figure()
        , .{call});
        defer t.allocator.free(source);
        for ([_]bool{ false, true }) |optimize| {
            var program = try compile(source, optimize);
            defer program.deinit();
            try t.expectEqual(@as(usize, 0), program.task_regions.len);
        }
    }
}

test "math reports invalid types domains overflow and integer bounds at the call" {
    for ([_][]const u8{ "math.seed(1.5)", "math.random(1)", "math.randint(0.5,2)", "math.randn(1)", "math.gamma(1mm)", "math.erf(true)", "math.beta(1)" }) |source| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, source, "invalid-math.huak", .{}, &diagnostic));
        try t.expect(diagnostic != null);
    }
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_][]const u8{ "math.randint(2,1)", "math.gamma(0)", "math.gamma(-2)", "math.lgamma(0)", "math.beta(-0.5,1)", "math.beta(1,0)", "math.gamma(172)" }) |source| {
        var program = try compile(source, true);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(machine.failure != null);
        try t.expectEqual(@as(usize, 0), machine.failure.?.diagnostic.span.start);
    }
}
