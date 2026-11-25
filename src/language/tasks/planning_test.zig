//! Tests of task planning through compile(): worker-safe builders, boundaries, captures, effects and barriers.
const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const task_plan = @import("plan.zig");
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const compile = compilation.compile;

test "task planning proves loop builders and transitive captures with and without optimization" {
    const input =
        \\import object.draw
        \\param offset:int=4
        \\a:=figure(1)
        \\b:=figure(2)
        \\fn coordinate(n:int)->int
        \\  return n+offset
        \\end
        \\fn figure(index:int)->picture
        \\  p:=picture(640, 480)
        \\  alias:=p
        \\  for i in 0:2 do
        \\    object.append(alias, draw(path((i,0),(coordinate(index),10))))
        \\  end
        \\  return p
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-loops.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        const region = program.task_regions[0];
        try std.testing.expectEqual(@as(usize, 2), region.tasks.len);
        try std.testing.expectEqual(region.tasks[0].start, region.start);
        try std.testing.expectEqual(region.tasks[1].end + 1, region.end);
        for (region.tasks) |task| {
            try std.testing.expectEqualSlices(u32, &.{0}, task.reads);
            try std.testing.expectEqual(bc.Op.store_global, program.functions[task.function].code[task.end].op);
            try std.testing.expectEqual(task.global, program.functions[task.function].code[task.end].a);
        }
    }
}

test "list append is a task boundary without consuming following picture calls" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\values:=[]
            \\values+=1
            \\first:=figure()
            \\second:=figure()
            \\fn figure()->picture
            \\    return picture(640, 480)
            \\end
            \\
        , "list-task-boundary.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        try std.testing.expectEqual(@as(usize, 2), program.task_regions[0].tasks.len);
    }
}

test "task planning records earlier picture producers and reads through helper captures" {
    const input =
        \\import object.{draw, append}
        \\base:=figure(0)
        \\a:=duplicate(base)
        \\b:=captured()
        \\fn figure(index:int)->picture
        \\  p:=picture(640, 480)
        \\  object.append(p, draw(path((index,0),(10,10))))
        \\  return p
        \\end
        \\fn duplicate(source:picture)->picture
        \\  p:=picture(640, 480)
        \\  append(p, copy(source))
        \\  return p
        \\end
        \\fn captured()->picture
        \\  return duplicate(a)
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-dag.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        const tasks = program.task_regions[0].tasks;
        try std.testing.expectEqual(@as(usize, 3), tasks.len);
        try std.testing.expectEqual(@as(usize, 0), tasks[0].reads.len);
        try std.testing.expectEqualSlices(u32, &.{tasks[0].global}, tasks[1].reads);
        try std.testing.expectEqualSlices(u32, &.{tasks[1].global}, tasks[2].reads);
    }
}

test "picture metadata and compound subpaths remain read-only worker inputs" {
    const input =
        \\import geometry.{compound, subpaths, rectangle}; import object.{region}; import object.fill
        \\source:=picture(80mm,40mm)
        \\first:=copy(source)
        \\second:=copy(source)
        \\fn copy(source:picture)->picture
        \\    result:=picture(source.width,source.height)
        \\    animated:bool:=source.animated
        \\    if not animated then
        \\        shape:=compound(subpaths(region(compound([rectangle((0mm,0mm),2mm,3mm),rectangle((4mm,0mm),2mm,3mm)]))))
        \\        object.append(result, fill(shape))
        \\    end
        \\    return result
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "picture-metadata.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        try std.testing.expectEqual(@as(usize, 2), program.task_regions[0].tasks.len);
        for (program.task_regions[0].tasks) |task| {
            try std.testing.expect(!task.uses_typst);
            try std.testing.expectEqualSlices(u32, &.{0}, task.reads);
        }
        var invalid: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "p:=picture(640, 480); x:=p.baseline; ", "picture-metadata-invalid.huak", .{ .optimize = optimize }, &invalid));
        try std.testing.expect(std.mem.indexOf(u8, invalid.?.text(), "picture has no member 'baseline'") != null);
    }
}

test "outline effects distinguish geometry from possibly typeset pictures and dynamic inputs" {
    for ([_]struct { kind: []const u8, value: []const u8, safe: bool, uses_typst: bool }{
        .{ .kind = "path", .value = "rectangle((0,0),10,10)", .safe = true, .uses_typst = false },
        .{ .kind = "object", .value = "picture()", .safe = true, .uses_typst = true },
        .{ .kind = "any", .value = "picture()", .safe = false, .uses_typst = false },
    }) |fixture| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator,
            \\import geometry.{{rectangle}}; import object.{{outlines}}; import object.append
            \\source:={s}
            \\first:=copy(source)
            \\second:=copy(source)
            \\fn copy(source:{s})->picture
            \\    result:=picture(640, 480)
            \\    shapes:object:=outlines(source)
            \\    append(result, shapes)
            \\    return result
            \\end
        , .{ fixture.value, fixture.kind });
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "outline-effects.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, if (fixture.safe) 1 else 0), program.task_regions.len);
        if (fixture.safe) for (program.task_regions[0].tasks) |task| {
            try std.testing.expectEqual(fixture.uses_typst, task.uses_typst);
        };
    };
}

test "task planning rejects alias returns external mutations and observable effects" {
    const bodies = [_][]const u8{
        "return source",
        "object.append(source, draw(path((0,0),(1,1))));return picture(640, 480)",
        "object.append(captured, draw(path((0,0),(1,1))));return picture(640, 480)",
        "p:=picture(640, 480);if flag then;p=source;end;object.append(p, draw(path((0,0),(1,1))));return p",
        "p:=picture(640, 480);while flag do;p=source;flag:=false;end;object.append(p, draw(path((0,0),(1,1))));return p",
        "print(1);return picture(640, 480)",
        "s:=solver();return picture(640, 480)",
        "xs:=[];xs+=1;return picture(640, 480)",
        "aliases:=[source];object.append(aliases[0], draw(path((0,0),(1,1))));return picture(640, 480)",
        "aliases:=[source];return aliases[0]",
    };
    for (bodies) |body| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "import object.draw; import solver.solver\ncaptured:=picture(640, 480)\na:=build(captured,true)\nb:=build(captured,false)\nfn build(source:picture,flag:bool)->picture\n{s}\nend", .{body});
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-effects.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 0), program.task_regions.len);
    };
}

test "task planning preserves barriers duplicate writes and basic block boundaries" {
    const input =
        \\param flag:bool=true
        \\d:=picture(); e:=picture(); a:=figure()
        \\b:=figure()
        \\print(0)
        \\a=figure()
        \\c:=figure()
        \\if flag then
        \\  d=figure()
        \\  e=figure()
        \\end
        \\f:=figure()
        \\g:=figure()
        \\fn figure()->picture;return picture(640, 480);end
        \\
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-boundaries.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 4), program.task_regions.len);
        for (program.task_regions) |region| {
            try std.testing.expectEqual(@as(usize, 2), region.tasks.len);
            for (program.functions[region.function].code) |instruction| {
                if (instruction.op == .jump or instruction.op == .jump_if_false)
                    try std.testing.expect(instruction.a <= region.start or instruction.a >= region.end);
            }
        }
        var repeated = try compile(std.testing.allocator, "a:=figure()\nb:=figure()\na=figure()\nc:=figure()\nfn figure()->picture;return picture(640, 480);end;", "task-repeated-writer.huak", .{ .optimize = optimize }, &diagnostic);
        defer repeated.deinit();
        try std.testing.expectEqual(@as(usize, 2), repeated.task_regions.len);
        for (repeated.task_regions) |region| {
            try std.testing.expectEqual(@as(usize, 2), region.tasks.len);
            try std.testing.expect(region.tasks[0].global != region.tasks[1].global);
        }
    }
}

test "task planning distinguishes stable object display from allocation identity" {
    const suffixes = [_][]const u8{
        "s:=str(a)",
        "s:=str([a])",
        "print(a)",
        "print([a])",
        "fn unused(p:picture)->string;return str(p);end",
        "s:=str(path((0,0),(1,1)))",
    };
    for (suffixes) |suffix| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "a:=figure()\nb:=figure()\nfn figure()->picture\ntemporary:=picture(640, 480)\nreturn picture(640, 480)\nend\n{s}", .{suffix});
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-identity.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        const observes_allocation = std.mem.indexOf(u8, suffix, "[a]") != null or std.mem.indexOf(u8, suffix, "path(") != null;
        try std.testing.expectEqual(@as(usize, if (observes_allocation) 0 else 1), program.task_regions.len);
    };
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "n:=str(12)\ns:=str(\"ok\")\na:=figure()\nb:=figure()\nfn figure()->picture;return picture(640, 480);end;", "task-simple-str.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
}

test "task planning skips ordinary scripts without allocating and bounds helper graph work" {
    var diagnostic: ?Diagnostic = null;
    var ordinary = try compile(std.testing.allocator, "n:=1\nfn unused()->picture;return picture(640, 480);end;", "task-no-candidates.huak", .{}, &diagnostic);
    defer ordinary.deinit();
    var no_allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const regions = try task_plan.build(no_allocations.allocator(), no_allocations.allocator(), &ordinary);
    try std.testing.expectEqual(@as(usize, 0), regions.len);
    var single = try compile(std.testing.allocator, "a:=figure()\nfn figure()->picture;return picture(640, 480);end;", "task-one-candidate.huak", .{}, &diagnostic);
    defer single.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try task_plan.build(no_allocations.allocator(), no_allocations.allocator(), &single)).len);

    // A reverse dependency chain needs one summary round per helper. Exceeding
    // the proof budget must preserve valid source as ordinary serial bytecode.
    const count = @import("effects.zig").limits.rounds + 2;
    var source_text: std.ArrayList(u8) = .empty;
    defer source_text.deinit(std.testing.allocator);
    try source_text.appendSlice(std.testing.allocator, "a:=f0()\nb:=f0()\n");
    for (0..count) |index| {
        const declaration = if (index + 1 == count)
            try std.fmt.allocPrint(std.testing.allocator, "fn f{d}()->picture;return picture(640, 480);end\n", .{index})
        else
            try std.fmt.allocPrint(std.testing.allocator, "fn f{d}()->picture;return f{d}();end\n", .{ index, index + 1 });
        defer std.testing.allocator.free(declaration);
        try source_text.appendSlice(std.testing.allocator, declaration);
    }
    try source_text.appendSlice(std.testing.allocator, "");
    var bounded = try compile(std.testing.allocator, source_text.items, "task-bounded-analysis.huak", .{}, &diagnostic);
    defer bounded.deinit();
    try std.testing.expectEqual(@as(usize, 0), bounded.task_regions.len);
}
