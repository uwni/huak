//! Constant propagation end to end: joins, diagnostics, host effects and identical native output.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const ModuleResolver = @import("../support/modules.zig").ModuleResolver;
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;

test "constant propagation preserves joins loop exits scalar coercion and runtime parameters" {
    const source =
        \\param choose:bool=false
        \\fn same(flag:bool)->int
        \\    value:=0; if flag then value=2 else value=2 end
        \\    return value*3
        \\end
        \\fn different(flag:bool)->int
        \\    value:=0; if flag then value=2 else value=3 end
        \\    return value*3
        \\end
        \\A:=2*3; B:=A+4
        \\folded:=0; if B>8 then folded=1 else panic("unreachable constant branch") end
        \\joined:=same(choose); diverged:=different(choose)
        \\rounded:float:=9007199254740993
        \\rounded_equal:=rounded==9007199254740993
        \\SIGN:=0.0; if choose then SIGN=-0.0 else SIGN=0.0 end
        \\sign:=SIGN
        \\LIMIT:=3*4; FACTOR:=2+3; total:=0
        \\for i in 0:LIMIT do
        \\    if i==2 then continue end
        \\    if i>8 then break end
        \\    total=total+FACTOR
        \\end
        \\j:=0
        \\while j<3 do total=total+1; j=j+1 end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var program = try l.compiler.compile(t.allocator, source, "constant-flow.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        if (optimize) {
            for (program.constants) |constant| if (constant == .string)
                try t.expect(!std.mem.eql(u8, constant.string, "unreachable constant branch"));
            for (program.functions) |function| {
                var products: usize = 0;
                for (function.code) |instruction| if (instruction.op == .multiply) {
                    products += 1;
                };
                if (std.mem.eql(u8, function.name, "same")) try t.expectEqual(@as(usize, 0), products);
                if (std.mem.eql(u8, function.name, "different")) try t.expectEqual(@as(usize, 1), products);
            }
        }
        for ([_]bool{ false, true }) |choose| {
            var machine = try l.Machine.init(t.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "choose", .value = if (choose) "true" else "false" }});
            try t.expectEqual(@as(i64, 1), machine.getGlobal("folded").?.int);
            try t.expectEqual(@as(i64, 6), machine.getGlobal("joined").?.int);
            try t.expectEqual(@as(i64, if (choose) 6 else 9), machine.getGlobal("diverged").?.int);
            try t.expect(!machine.getGlobal("rounded_equal").?.boolean);
            try t.expectEqual(@as(u64, if (choose) 0x8000000000000000 else 0), @as(u64, @bitCast(machine.getGlobal("sign").?.number)));
            try t.expectEqual(@as(i64, 43), machine.getGlobal("total").?.int);
            try t.expectEqual(@as(i64, 3), machine.getGlobal("j").?.int);
        }
    }
}

test "constant propagation retains uninitialized and arithmetic diagnostics" {
    const sources = [_][]const u8{
        "param choose:bool=false\nif not choose then print(MAYBE) end\nMAYBE:=7\nresult:=MAYBE",
        "A:=9223372036854775807\nresult:=A+1",
        "A:=10\nresult:=A/0",
    };
    for (sources) |source| {
        var expected: ?l.compiler.Diagnostic = null;
        for ([_]bool{ false, true }) |optimize| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            var program = try l.compiler.compile(t.allocator, source, "constant-errors.huak", .{ .optimize = optimize }, &diagnostic);
            defer program.deinit();
            var machine = try l.Machine.init(t.allocator, &program, .{}, .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            const failure = machine.failure.?.diagnostic;
            try t.expect(machine.getGlobal("result") == null);
            if (expected) |original| {
                try t.expectEqualStrings(original.text(), failure.text());
                try t.expectEqualDeep(original.span, failure.span);
            } else expected = failure;
        }
    }
}

test "constant propagation respects host effects through direct calls user functions and imports" {
    const BuiltinId = @FieldType(@FieldType(l.bytecode.Export, "target"), "builtin");
    const Mutation = struct {
        machine: ?*l.Machine = null,
        calls: usize = 0,

        fn call(context: ?*anyopaque, _: std.mem.Allocator, id: BuiltinId, args: []const l.types.Value, _: ?*l.Machine) !l.types.Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print or args.len != 1 or args[0] != .string) return error.UnexpectedHostCall;
            self.calls += 1;
            const machine = self.machine.?;
            for (machine.program.global_names, machine.globals) |name, *value| {
                if (std.mem.eql(u8, name, "x")) value.* = .{ .int = 10 };
            }
            return .unit;
        }
    };
    for ([_][]const u8{
        "x:=1\nprint(\"mutate\")\nresult:=x+1",
        "fn touch() print(\"mutate\") end\nx:=1\ntouch()\nresult:=x+1",
        "x:=1\nimport \"mutator.huak\"\nresult:=x+1",
    }) |source| for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var resolver: ModuleResolver = .{ .sources = &.{.{ .name = "/native/mutator.huak", .source = "print(\"mutate\")" }} };
        var program = try l.compiler.compile(t.allocator, source, "/native/main.huak", .{ .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } }, .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var mutation: Mutation = .{};
        var machine = try l.Machine.init(t.allocator, &program, .{ .ptr = &mutation, .vtable = &.{ .call_builtin = Mutation.call } }, .{});
        defer machine.deinit();
        mutation.machine = &machine;
        _ = try machine.execute(&.{});
        try t.expectEqual(@as(usize, 1), mutation.calls);
        try t.expectEqual(@as(i64, 11), machine.getGlobal("result").?.int);
    };
}

test "constant propagation produces the same native SVG PDF and mutable path inputs" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, pen, path, draw, label, picture};param variant:bool=false
        \\FACTOR:=2*3; EDGE:=FACTOR+4
        \\LEFT:=0; if EDGE>8 then LEFT=EDGE else LEFT=-1000 end
        \\TOP:=0; if variant then TOP=20 else TOP=30 end
        \\points:=[(LEFT*1mm,5mm),(30mm,TOP*1mm),(50mm,5mm)]
        \\alias:=points
        \\fn add_point(items:list) items+=(70mm,25mm) end
        \\add_point(alias)
        \\pic:=picture(100mm,70mm)
        \\object.append(pic, object.draw(path(points), pen(rgb(0.15,0.3,0.7),0.5mm)))
        \\caption:=typ[Propagation Ω]
        \\object.append(pic, object.label(caption, (5mm,55mm)))
    ;
    var expected_svg: [2]?[]u8 = .{ null, null };
    var expected_pdf: [2]?[]u8 = .{ null, null };
    defer for (expected_svg) |bytes| if (bytes) |value| t.allocator.free(value);
    defer for (expected_pdf) |bytes| if (bytes) |value| t.allocator.free(value);
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        if (optimize) {
            var conditions: usize = 0;
            for (program.functions[program.entry].code) |instruction| if (instruction.op == .jump_if_false) {
                conditions += 1;
            };
            try t.expectEqual(@as(usize, 1), conditions);
        }
        for ([_]bool{ false, true }, 0..) |variant, index| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "variant", .value = if (variant) "true" else "false" }});
            try t.expectEqual(@as(usize, 4), l.types.sequence(machine.getGlobal("points").?).?.len);
            var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
            defer svg.deinit();
            var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
            try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
            if (expected_svg[index]) |bytes| {
                try t.expectEqualSlices(u8, bytes, svg.bytes());
                try t.expectEqualSlices(u8, expected_pdf[index].?, pdf.bytes());
            } else {
                expected_svg[index] = try t.allocator.dupe(u8, svg.bytes());
                expected_pdf[index] = try t.allocator.dupe(u8, pdf.bytes());
            }
            const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            try t.expect(std.mem.indexOf(u8, text, "Propagation Ω") != null);
        }
    }
}
