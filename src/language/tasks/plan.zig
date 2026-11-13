//! Build isolated picture tasks from checked, linked and optimized bytecode.
//! A region contains adjacent RHS/store pairs in a single basic block. Reads
//! refer to earlier task producers or to the state at region entry, preserving
//! forward reads and initialization failures instead of inventing future values.
const std = @import("std");
const bc = @import("../bytecode.zig");
const effects = @import("effects.zig");
const Allocator = std.mem.Allocator;

pub fn build(allocator: Allocator, program: *const bc.Program) Allocator.Error![]const bc.TaskRegion {
    // Most scripts contain no user picture builders at all. Avoid constructing
    // a function CFG (and multiplying allocation-failure test cases) for them.
    if (!hasCandidate(program)) return &.{};
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const summaries = (try effects.analyze(scratch, program)) orelse return &.{};
    if (try effects.observesIdentity(scratch, program, summaries)) return &.{};
    var regions: std.ArrayList(bc.TaskRegion) = .empty;
    var remaining: usize = effects.limits.work;
    for (program.functions, 0..) |function, index| {
        if (!program.isEntry(index) or function.parameters.len != 0 or function.code.len == 0) continue;
        const depths = (try stackDepths(scratch, function)) orelse continue;
        const boundary = try scratch.alloc(bool, function.code.len);
        @memset(boundary, false);
        boundary[0] = true;
        for (function.code, 0..) |instruction, ip| switch (instruction.op) {
            .jump, .jump_if_false => {
                if (instruction.a < boundary.len) boundary[instruction.a] = true;
                if (ip + 1 < boundary.len) boundary[ip + 1] = true;
            },
            else => {},
        };
        var tasks: std.ArrayList(bc.Task) = .empty;
        var ip: usize = 0;
        while (ip < function.code.len) {
            if (boundary[ip]) try flush(scratch, &regions, &tasks);
            if (depths[ip] == null or depths[ip].? != 0) {
                try flush(scratch, &regions, &tasks);
                ip += 1;
                continue;
            }
            const start = ip;
            var end = ip;
            while (end < function.code.len) : (end += 1) {
                if (end != start and boundary[end]) break;
                switch (function.code[end].op) {
                    .jump, .jump_if_false, .return_value, .halt, .import_module, .setup_typst, .typst, .show_rule, .store_local, .load_local, .list_append, .list_append_items, .make_dict, .make_record, .set_index, .set_field => break,
                    else => {},
                }
                if (function.code[end].op == .store_global or function.code[end].op == .pop) break;
            }
            if (end < function.code.len and !boundary[end] and function.code[end].op == .store_global and depths[end] != null and depths[end].? == 1) {
                const global = function.code[end].a;
                if (global < program.global_types.len and global < program.readonly_globals.len and
                    (program.global_types[global] == .picture or program.global_types[global] == .object) and !program.readonly_globals[global])
                {
                    // Include read-set initialization and duplicate-writer
                    // checks, not only opcode visits, in the planning budget.
                    const cost = end - start + program.global_types.len + tasks.items.len;
                    if (cost > remaining) return &.{};
                    remaining -= cost;
                    const result = try effects.expression(scratch, program, summaries, function.code[start..end], &remaining);
                    if (remaining == 0) return &.{};
                    if (result) |summary| {
                        if (summary.reads.len > remaining) return &.{};
                        remaining -= summary.reads.len;
                        // This compact contract has no prior-version read slot.
                        // Keep self-rebinding serial rather than creating a cycle.
                        if (std.mem.indexOfScalar(u32, summary.reads, global) == null) {
                            if ((tasks.items.len != 0 and tasks.items[tasks.items.len - 1].end + 1 != start) or containsWrite(tasks.items, global))
                                try flush(scratch, &regions, &tasks);
                            try tasks.append(scratch, .{ .function = @intCast(index), .start = @intCast(start), .end = @intCast(end), .global = global, .reads = summary.reads, .uses_typst = summary.uses_typst });
                            ip = end + 1;
                            continue;
                        }
                    }
                }
            }
            try flush(scratch, &regions, &tasks);
            ip = if (end > start) end else start + 1;
        }
        try flush(scratch, &regions, &tasks);
    }
    return duplicate(allocator, regions.items);
}

fn hasCandidate(program: *const bc.Program) bool {
    if (program.entry < program.functions.len and entryCallsBuilder(program, program.entry)) return true;
    for (program.modules) |module| if (module.entry < program.functions.len and entryCallsBuilder(program, module.entry)) return true;
    return false;
}

fn entryCallsBuilder(program: *const bc.Program, index: u32) bool {
    var count: usize = 0;
    for (program.functions[index].code) |instruction| {
        if (instruction.op == .call and instruction.a < program.functions.len and (program.functions[instruction.a].result == .picture or program.functions[instruction.a].result == .object)) {
            count += 1;
            if (count == 2) return true;
        }
    }
    return false;
}

fn containsWrite(tasks: []const bc.Task, global: u32) bool {
    for (tasks) |task| if (task.global == global) return true;
    return false;
}

fn flush(allocator: Allocator, regions: *std.ArrayList(bc.TaskRegion), tasks: *std.ArrayList(bc.Task)) !void {
    if (tasks.items.len >= 2) {
        const first = tasks.items[0];
        const last = tasks.items[tasks.items.len - 1];
        try regions.append(allocator, .{ .function = first.function, .start = first.start, .end = last.end + 1, .tasks = try allocator.dupe(bc.Task, tasks.items) });
    }
    tasks.clearRetainingCapacity();
}

fn duplicate(allocator: Allocator, regions: []const bc.TaskRegion) ![]const bc.TaskRegion {
    const output = try allocator.alloc(bc.TaskRegion, regions.len);
    errdefer allocator.free(output);
    var completed: usize = 0;
    errdefer for (output[0..completed]) |region| {
        for (region.tasks) |task| allocator.free(task.reads);
        allocator.free(region.tasks);
    };
    for (regions, output) |region, *out| {
        const tasks = try allocator.alloc(bc.Task, region.tasks.len);
        errdefer allocator.free(tasks);
        var task_count: usize = 0;
        errdefer for (tasks[0..task_count]) |task| allocator.free(task.reads);
        for (region.tasks, tasks) |task, *destination| {
            destination.* = task;
            destination.reads = try allocator.dupe(u32, task.reads);
            task_count += 1;
        }
        out.* = region;
        out.tasks = tasks;
        completed += 1;
    }
    return output;
}

/// Establish actual reachable stack heights before choosing an empty-stack
/// task entry. This also prevents a jump into the middle of a candidate RHS.
fn stackDepths(allocator: Allocator, function: bc.Function) !?[]const ?usize {
    const depths = try allocator.alloc(?usize, function.code.len);
    @memset(depths, null);
    depths[0] = 0;
    var pending: std.ArrayList(usize) = .empty;
    try pending.append(allocator, 0);
    while (pending.pop()) |ip| {
        const instruction = function.code[ip];
        const effect = instruction.stackEffect();
        const depth = depths[ip].?;
        if (depth < effect.consumed) return null;
        const next = std.math.add(usize, depth - effect.consumed, effect.produced) catch return null;
        for (instruction.successors(ip)) |successor| if (successor) |destination| {
            if (!try setDepth(allocator, depths, &pending, destination, next)) return null;
        };
    }
    return depths;
}

fn setDepth(allocator: Allocator, depths: []?usize, pending: *std.ArrayList(usize), ip: usize, depth: usize) !bool {
    if (ip >= depths.len) return false;
    if (depths[ip]) |existing| return existing == depth;
    depths[ip] = depth;
    try pending.append(allocator, ip);
    return true;
}

const ProofTest = struct {
    const builtin = @import("../builtin.zig");
    const root = [_]bc.Instruction{
        .{ .op = .constant, .a = 0 },     .{ .op = .constant, .a = 1 },               .{ .op = .bind_arguments, .a = 0, .b = 2 },
        .{ .op = .call, .a = 1, .b = 2 }, .{ .op = .store_global, .a = 1 },           .{ .op = .constant, .a = 1 },
        .{ .op = .constant, .a = 0 },     .{ .op = .bind_arguments, .a = 0, .b = 2 }, .{ .op = .call, .a = 1, .b = 2 },
        .{ .op = .store_global, .a = 2 }, .{ .op = .halt },
    };
    const builder = [_]bc.Instruction{
        .{ .op = .load_local, .a = 0 },                                         .{ .op = .load_local, .a = 1 },
        .{ .op = .call_builtin, .a = @backingInt(builtin.Id.picture), .b = 2 }, .{ .op = .store_local, .a = 2 },
        .{ .op = .load_global, .a = 0 },                                        .{ .op = .load_local, .a = 2 },
        .{ .op = .constant, .a = 2 },                                           .{ .op = .bind_arguments, .a = 1, .b = 3 },
        .{ .op = .call_builtin, .a = @backingInt(builtin.Id.draw), .b = 3 },    .{ .op = .pop },
        .{ .op = .load_local, .a = 2 },                                         .{ .op = .return_value },
    };
    const bindings = [_]bc.ArgumentBinding{
        .{ .slots = &.{ 1, 0 }, .parameter_count = 2 },
        .{ .slots = &.{ 1, 0, 2 }, .parameter_count = 3 },
    };
    fn program(allocator: Allocator) bc.Program {
        return .{
            .arena = .init(allocator),
            .source_text = "",
            .name = "proof",
            .functions = &.{
                .{ .name = "script", .code = &root, .parameters = &.{}, .result = .unit, .local_types = &.{} },
                .{ .name = "figure", .code = &builder, .parameters = &.{ .int, .int }, .result = .picture, .local_types = &.{ .int, .int, .picture } },
            },
            .constants = &.{ .{ .int = 20 }, .{ .int = 30 }, .omitted, .{ .string = "count" } },
            .records = &.{.{ .name = "Empty", .fields = &.{} }},
            .argument_bindings = &bindings,
            .parameters = &.{},
            .global_names = &.{ "curve", "first", "second" },
            .global_types = &.{ .path, .picture, .picture },
            .readonly_globals = &.{ false, false, false },
        };
    }
    fn freeRegions(allocator: Allocator, regions: []const bc.TaskRegion) void {
        for (regions) |region| {
            for (region.tasks) |task| allocator.free(task.reads);
            allocator.free(region.tasks);
        }
        allocator.free(regions);
    }
};

fn namedAllocationExercise(allocator: Allocator) !void {
    var program = ProofTest.program(allocator);
    defer program.deinit();
    const regions = try build(allocator, &program);
    defer ProofTest.freeRegions(allocator, regions);
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(@as(usize, 2), regions[0].tasks.len);
    for (regions[0].tasks) |task| try std.testing.expectEqualSlices(u32, &.{0}, task.reads);
}

test "named argument permutations preserve picture proofs and every allocation failure cleans up" {
    try namedAllocationExercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, namedAllocationExercise, .{});
}

test "aggregate statements stay serial while following picture construction remains parallel" {
    for ([_]bc.Op{ .make_dict, .make_record }) |operation| {
        var program = ProofTest.program(std.testing.allocator);
        defer program.deinit();
        const a = program.arena.allocator();
        const root = try a.alloc(bc.Instruction, ProofTest.root.len + 2);
        root[0] = .{ .op = operation };
        root[1] = .{ .op = .pop };
        @memcpy(root[2..], &ProofTest.root);
        const functions = try a.dupe(bc.Function, program.functions);
        functions[0].code = root;
        program.functions = functions;
        const regions = try build(std.testing.allocator, &program);
        defer ProofTest.freeRegions(std.testing.allocator, regions);
        try std.testing.expectEqual(@as(usize, 1), regions.len);
        try std.testing.expectEqual(@as(u32, 2), regions[0].start);
        try std.testing.expectEqual(@as(usize, 2), regions[0].tasks.len);
        const builder = try a.alloc(bc.Instruction, ProofTest.builder.len + 2);
        builder[0] = root[0];
        builder[1] = root[1];
        @memcpy(builder[2..], &ProofTest.builder);
        functions[1].code = builder;
        const serial = try build(std.testing.allocator, &program);
        defer ProofTest.freeRegions(std.testing.allocator, serial);
        try std.testing.expectEqual(@as(usize, 0), serial.len);
    }
}

test "malformed permutations and exhausted proof budgets fall back to ordered execution" {
    for ([_]bc.ArgumentBinding{
        .{ .slots = &.{ 0, 0 }, .parameter_count = 2 },
        .{ .slots = &.{ 0, 2 }, .parameter_count = 2 },
        .{ .slots = &.{0}, .parameter_count = 2 },
        .{ .slots = &.{ 0, 1 }, .parameter_count = 3 },
    }) |invalid| {
        var program = ProofTest.program(std.testing.allocator);
        defer program.deinit();
        program.argument_bindings = &.{ invalid, ProofTest.bindings[1] };
        const regions = try build(std.testing.allocator, &program);
        defer ProofTest.freeRegions(std.testing.allocator, regions);
        try std.testing.expectEqual(@as(usize, 0), regions.len);
    }
    var program = ProofTest.program(std.testing.allocator);
    defer program.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const summaries = (try effects.analyze(arena.allocator(), &program)).?;
    var remaining: usize = 1;
    try std.testing.expect((try effects.expression(arena.allocator(), &program, summaries, ProofTest.root[0..4], &remaining)) == null);
    try std.testing.expectEqual(@as(usize, 0), remaining);
}
