//! Helpers shared by the compiler tests: global types, in-memory modules, and Typst compilation and request checks.
const std = @import("std");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Type = bc.Type;
const Value = bc.Value;
const ModuleGraph = @import("../ModuleGraph.zig");
const ResolvedSource = ModuleGraph.ResolvedSource;
const Diagnostic = source.Diagnostic;
const compilation = @import("../compiler.zig");
const CompileOptions = compilation.CompileOptions;
const compile = compilation.compile;

pub fn testGlobalType(program: *const bc.Program, name: []const u8) Type {
    for (program.global_names, program.global_types) |binding, kind| if (std.mem.eql(u8, binding, name)) return kind;
    unreachable;
}

pub const ModuleTestSources = struct {
    pub fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
        const files = [_]ResolvedSource{
            .{ .name = "left.huak", .source = "import \"shared.huak\" as shared\nexport get\nfn get()->int;return shared.get();end" },
            .{ .name = "right.huak", .source = "import \"shared.huak\" as shared\nexport get\nfn get()->int;return shared.get();end" },
            .{ .name = "shared.huak", .source = "param count=3\nprint(\"initialized\")\nexport get\nfn get()->int;return count;end" },
        };
        for (files) |file| if (std.mem.eql(u8, file.name, path)) return file;
        return error.FileNotFound;
    }
    pub fn count(ctx: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*@import("../Machine.zig")) !Value {
        if (id != .print or args.len != 1) return error.UnexpectedBuiltin;
        const calls: *usize = @ptrCast(@alignCast(ctx.?));
        calls.* += 1;
        return .unit;
    }
};

pub fn typstOptions(optimize: bool) CompileOptions {
    return .{ .optimize = optimize, .source_parser = Parser.TestSourceParser.parser };
}

pub fn typstCompile(allocator: std.mem.Allocator, input: []const u8, optimize: bool) !bc.Program {
    var diagnostic: ?Diagnostic = null;
    return compile(allocator, input, "typst-reads.huak", typstOptions(optimize), &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("typst reads compiler: {s}\n", .{detail.text()});
        return err;
    };
}

const ExpectedRequest = struct {
    op: bc.Op = .typst,
    /// Huak names, or ".member" for a show value.
    names: []const []const u8,
    loads: ?[]const bc.Op = null,
    /// Globals loaded for the captures.
    globals: ?[]const []const u8 = null,
    /// The code uses `huak` as a whole value.
    whole: bool = false,
    /// The name a typ.module is made with.
    module: ?[]const u8 = null,
};

/// Checks the Typst requests of `function` in code order.
pub fn expectTypstRequests(program: *const bc.Program, function: bc.Function, expected: []const ExpectedRequest) !void {
    var index: usize = 0;
    for (function.code, 0..) |instruction, position| if (instruction.op == .typst or instruction.op == .typst_module) {
        try std.testing.expect(index < expected.len);
        const want = expected[index];
        try std.testing.expectEqual(want.op, instruction.op);
        const pairs: usize = instruction.typstCaptures().pairs;
        try std.testing.expectEqual(want.names.len, pairs);
        try std.testing.expectEqual(want.whole, instruction.typstCaptures().whole);
        // A module's name precedes its captured pairs.
        const named = instruction.op == .typst_module;
        try std.testing.expectEqual(pairs * 2 + @intFromBool(named), instruction.stackEffect().consumed);
        if (want.module) |name| {
            const constant = function.code[position - pairs * 2 - 1];
            try std.testing.expectEqual(bc.Op.constant, constant.op);
            try std.testing.expectEqualStrings(name, program.constants[constant.a].string);
        }
        try std.testing.expectEqual(@as(usize, 1), instruction.stackEffect().produced);
        const inputs = function.code[position - pairs * 2 .. position];
        for (want.names, 0..) |name, capture| {
            try std.testing.expectEqual(bc.Op.constant, inputs[capture * 2].op);
            try std.testing.expectEqualStrings(name, program.constants[inputs[capture * 2].a].string);
            const load = inputs[capture * 2 + 1];
            if (want.loads) |loads| try std.testing.expectEqual(loads[capture], load.op);
            if (want.globals) |globals| {
                try std.testing.expectEqual(bc.Op.load_global, load.op);
                try std.testing.expectEqualStrings(globals[capture], program.global_names[load.a]);
            }
        }
        index += 1;
    };
    try std.testing.expectEqual(expected.len, index);
}

pub fn expectTypstFailure(input: []const u8, message: []const u8) !void {
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "typst-errors.huak", typstOptions(false), &diagnostic));
    std.testing.expectEqualStrings(message, diagnostic.?.text()) catch |err| {
        std.debug.print("input: {s}\n", .{input});
        return err;
    };
}
