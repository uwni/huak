//! Name/type resolution and lowering to a compact, linear instruction stream.
const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("Parser.zig");
const source = @import("source.zig");
const bc = @import("bytecode.zig");
const ModuleGraph = @import("ModuleGraph.zig");
const optimizer = @import("optimizer.zig");
const task_plan = @import("tasks/plan.zig");
pub const ResolvedSource = ModuleGraph.ResolvedSource;
pub const ImportResolver = ModuleGraph.ImportResolver;
pub const SourceParser = Parser.SourceParser;
const lowering = @import("compiler/lowering.zig");
const testing = @import("compiler/testing.zig");
const lowerGraph = lowering.lowerGraph;
const ModuleTestSources = testing.ModuleTestSources;
pub const CompileOptions = struct {
    source_parser: anyerror!?SourceParser = null,
    import_resolver: ?ImportResolver = null,
    optimize: bool = true,
};
pub const Diagnostic = source.Diagnostic;

/// Module source survives in storage. The AST belongs to syntax. Providers
/// are only borrowed while resolving the root and its imports.
pub fn parseModules(storage: std.mem.Allocator, syntax: std.mem.Allocator, input: []const u8, name: []const u8, options: CompileOptions, diagnostic: *?Diagnostic) !ModuleGraph {
    diagnostic.* = null;
    var graph = ModuleGraph.init(storage, syntax, .{ .source_parser = options.source_parser }, options.import_resolver, diagnostic);
    try graph.root(name, input);
    graph.options = .{};
    graph.resolver = null;
    return graph;
}

/// Run the same parsing, linking and semantic checks without producing an
/// executable Program, optimizing bytecode or scheduling picture tasks.
pub fn check(allocator: std.mem.Allocator, input: []const u8, name: []const u8, options: CompileOptions, diagnostic: *?Diagnostic) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const graph = try parseModules(arena.allocator(), arena.allocator(), input, name, options, diagnostic);
    try checkGraph(allocator, &graph);
}

/// Check a graph already parsed by an editor tool. The check owns its
/// temporary lowering state; the caller keeps the graph and its source ranges.
pub fn checkGraph(allocator: std.mem.Allocator, graph: *const ModuleGraph) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try lowerGraph(graph, arena.allocator(), arena.allocator());
}

pub fn compile(allocator: std.mem.Allocator, input: []const u8, name: []const u8, options: CompileOptions, diagnostic: *?Diagnostic) !bc.Program {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    var syntax_arena: std.heap.ArenaAllocator = .init(allocator);
    defer syntax_arena.deinit();
    const graph = try parseModules(memory, syntax_arena.allocator(), input, name, options, diagnostic);
    var build = try lowerGraph(&graph, memory, syntax_arena.allocator());
    if (options.optimize) {
        {
            var pool_index = optimizer.PoolIndex.init(allocator);
            defer pool_index.deinit();
            for (build.functions.items) |*function| function.code = try optimizer.optimize(memory, function.code, &build.constants, .{
                .global_types = build.types.items,
                .local_types = function.local_types,
                .argument_bindings = build.argument_bindings.items,
                .scratch_allocator = allocator,
                .pool_index = &pool_index,
            });
        }
        try optimizer.compactConstants(memory, build.functions.items, &build.constants);
    }
    // Finish every arena allocation before copying its owner into Program.
    // A later allocation can grow the arena and make an earlier owner copy
    // omit the newly allocated block during deinit.
    const functions = try build.functions.toOwnedSlice();
    const constants = try build.constants.toOwnedSlice();
    const parameters = try build.parameters.toOwnedSlice();
    const records = try build.records.toOwnedSlice();
    const argument_bindings = try build.argument_bindings.toOwnedSlice();
    const groups = try memory.dupe(bc.PrecedenceGroup, build.precedence.groups.items);
    const global_names = try build.names.toOwnedSlice();
    const global_types = try build.types.toOwnedSlice();
    const readonly = try build.readonly.toOwnedSlice();
    var program: bc.Program = .{ .arena = undefined, .source_text = build.modules[0].source_text, .name = build.modules[0].name, .functions = functions, .constants = constants, .records = records, .argument_bindings = argument_bindings, .parameters = parameters, .exports = build.modules[0].exports, .outputs = build.outputs, .modules = build.modules, .groups = groups, .global_names = global_names, .global_types = global_types, .readonly_globals = readonly, .entry = build.modules[0].entry };
    program.argument_names = try build.argument_names.toOwnedSlice(memory);
    // Planning works in the caller's allocator and releases its state here;
    // only the regions join Program memory.
    program.task_regions = try task_plan.build(memory, allocator, &program);
    // The regions are allocated in memory; copy the arena owner only afterwards.
    program.arena = arena;
    return program;
}

test "check preserves semantic and imported diagnostics without producing a Program" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "middle.huak")) return .{ .name = "middle.huak", .source = "import \"broken.huak\" as broken\nexport value:=broken.value" };
            if (std.mem.eql(u8, path, "broken.huak")) return .{ .name = "broken.huak", .source = "export value:=not_declared" };
            return error.FileNotFound;
        }
    };
    var marker: u8 = 0;
    const cases = [_][]const u8{
        "value:=not_declared",
        "value:int:=\"wrong\"",
        "fn bad()->int return true end",
        "export missing",
        "fn broken(",
        "import \"middle.huak\" as middle",
        "typ.show missing.style\nvalue:=typ[]",
        "value:=typ[invalid fixture]",
    };
    for (cases) |input| for ([_]bool{ false, true }) |optimize| {
        var expected: ?Diagnostic = null;
        var actual: ?Diagnostic = null;
        const options: CompileOptions = .{ .optimize = optimize, .source_parser = .{ .ptr = &marker, .vtable = &.{ .block = emptyTypstFixture } }, .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } } };
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "check-root.huak", options, &expected));
        try std.testing.expectError(error.LanguageError, check(std.testing.allocator, input, "check-root.huak", options, &actual));
        try std.testing.expectEqualStrings(expected.?.text(), actual.?.text());
        try std.testing.expectEqualStrings(expected.?.fileName().?, actual.?.fileName().?);
        try std.testing.expectEqualDeep(expected.?.span, actual.?.span);
        try std.testing.expectEqualDeep(expected.?.position(""), actual.?.position(""));
    };
    var diagnostic: ?Diagnostic = null;
    try check(std.testing.allocator, "value:=typ[]\npanic(\"checking must not execute\")", "native-block-check.huak", .{ .source_parser = .{ .ptr = &marker, .vtable = &.{ .block = emptyTypstFixture } } }, &diagnostic);
    try std.testing.expect(diagnostic == null);
}

fn checkAllocationExercise(allocator: std.mem.Allocator) !void {
    var marker: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    try check(allocator,
        \\import "left.huak" as left
        \\import "right.huak" as right
        \\struct Entry value:int=3 end
        \\items:=[]
        \\for i in 0:3 do items+=[Entry(value:i)] end
        \\export result:=left.get()+right.get()
    , "check-allocation.huak", .{ .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = ModuleTestSources.resolve } } }, &diagnostic);
    try std.testing.expect(diagnostic == null);
}

test "check releases both semantic arenas on success and every allocation failure" {
    try checkAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), checkAllocationExercise, .{});
}

test "precedence metadata survives caller source release and grouped signed minimums" {
    const allocator = std.testing.allocator;
    const original = try allocator.dupe(u8,
        \\precedence stable_group
        \\ below addition
        \\ above path
        \\end
        \\export stable_group
        \\param n=-(9223372036854775808)
        \\answer:=-(9223372036854775808)
    );
    var diagnostic: ?Diagnostic = null;
    var program = compile(allocator, original, "owned-precedence.huak", .{}, &diagnostic) catch |err| {
        allocator.free(original);
        return err;
    };
    allocator.free(original);
    defer program.deinit();
    const group = program.groups[program.exports[0].target.precedence];
    try std.testing.expectEqualStrings("stable_group", group.name);
    try std.testing.expectEqual(ast.Associativity.none, group.associativity);
    var machine = try @import("Machine.zig").init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(std.math.minInt(i64), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(std.math.minInt(i64), machine.getGlobal("n").?.int);
}

test "signed minimum literal defaults and owned source survive caller storage" {
    var input = "param n:int=-9223372036854775808\nx:=n\n".*;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, &input, "owned.huak", .{}, &diagnostic);
    defer program.deinit();
    @memset(&input, 'x');
    try std.testing.expectEqual(std.math.minInt(i64), program.parameters[0].default.?.int);
    try std.testing.expectEqualStrings("n", program.parameters[0].name);
    try std.testing.expect(std.mem.startsWith(u8, program.source_text, "param n:"));
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "x:=9223372036854775808\n", "overflow.huak", .{}, &diagnostic));
}

test "decoded strings outlive the temporary syntax arena" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "param title:string=\"中文\\n\"\nx:=\"\\u03bb\"\n", "strings.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqualStrings("中文\n", program.parameters[0].default.?.string);
    try std.testing.expectEqualStrings("λ", program.constants[0].string);
}

// A fixed empty-block fixture exercises compiler lowering only. Real native
// parsing, evaluation and rendering are covered by the integration suites.
fn emptyTypstFixture(_: *anyopaque, input: []const u8) !usize {
    if (!std.mem.startsWith(u8, input, "[]")) return error.UnexpectedTestBlock;
    return 2;
}

test {
    _ = @import("compiler/aggregates_test.zig");
    _ = @import("compiler/blocks_test.zig");
    _ = @import("compiler/calls_test.zig");
    _ = @import("compiler/defaults_test.zig");
    _ = @import("compiler/exports_test.zig");
    _ = @import("compiler/imports_test.zig");
    _ = @import("compiler/expressions_test.zig");
    _ = @import("compiler/infix_test.zig");
    _ = @import("compiler/mixfix_test.zig");
    _ = @import("compiler/typst_reads_test.zig");
    _ = @import("compiler/typst_show_test.zig");
}
