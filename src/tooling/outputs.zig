//! Picture output choices derived from compiled bindings without executing them.
const std = @import("std");
const bytecode = @import("../language/bytecode.zig");

pub const Candidate = struct {
    /// The CLI selector stays `default` when its display name is a named alias.
    name: []const u8,
    label: []const u8,
    default: bool,
};

/// Candidate strings borrow Program; the returned slice belongs to allocator.
pub fn collect(allocator: std.mem.Allocator, program: *const bytecode.Program) ![]Candidate {
    const shared = defaultSource(program);
    var label: ?[]const u8 = null;
    if (shared) |global| for (program.outputs) |output| {
        if (output.global == global and !isDefault(output.name) and isPicture(program, output)) {
            label = output.name;
            break;
        }
    };
    var result: std.ArrayList(Candidate) = .empty;
    errdefer result.deinit(allocator);
    var merged = false;
    for (program.outputs) |output| {
        if (!isPicture(program, output)) continue;
        const default = isDefault(output.name);
        if (label) |alias| {
            if (default) continue;
            if (!merged and output.global == shared.?) {
                try result.append(allocator, .{ .name = "default", .label = alias, .default = true });
                merged = true;
                continue;
            }
        }
        try result.append(allocator, .{ .name = output.name, .label = if (default) "Default picture" else output.name, .default = default });
    }
    return result.toOwnedSlice(allocator);
}

fn isDefault(name: []const u8) bool {
    return std.mem.eql(u8, name, "default");
}

fn isPicture(program: *const bytecode.Program, output: bytecode.Output) bool {
    const kind = program.global_types[output.global];
    return kind == .picture or kind == .any;
}

/// A default is a snapshot. It shares a named binding's final value only when
/// a direct global read created it and that binding cannot subsequently change.
fn defaultSource(program: *const bytecode.Program) ?u32 {
    const output = program.outputNamed("default") orelse return null;
    if (!isPicture(program, output.*)) return null;
    const destination = output.global;
    const code = program.functions[program.entry].code;
    var store: ?usize = null;
    for (code, 0..) |instruction, index| if (instruction.op == .store_global and instruction.a == destination) {
        if (store != null or index == 0 or code[index - 1].op != .load_global) return null;
        store = index;
    };
    const saved = store orelse return null;
    const origin = code[saved - 1].a;
    if (origin == destination) return null;
    for (code, 0..) |instruction, index| {
        if (index > saved and instruction.op == .store_global and instruction.a == origin) return null;
        switch (instruction.op) {
            .jump, .jump_if_false => {
                // Reject entry into the store without its load and any edge
                // which could repeat the snapshot after an earlier rebinding.
                if (instruction.a == saved or (index > saved and instruction.a <= saved)) return null;
            },
            else => {},
        }
    }
    var initializer: ?usize = null;
    var root_writes = false;
    for (program.functions, 0..) |function, index| for (function.code) |instruction| {
        if (instruction.op != .store_global or instruction.a != origin) continue;
        if (index == program.entry) {
            root_writes = true;
        } else {
            // Imported globals belong to one module initializer. A completed
            // import cannot run it again; ordinary functions may not rebind it.
            if (!program.isEntry(index)) return null;
            if (initializer) |earlier| {
                if (earlier != index) return null;
            } else initializer = index;
        }
    };
    if (root_writes and initializer != null) return null;
    return origin;
}

test "default output aliases merge only when their final binding stays the same" {
    const compiler = @import("../language/compiler.zig");
    const cases = [_]struct { source: []const u8, merged: bool }{
        .{ .source = "import paint.*\nchart:=picture(640, 480);default chart", .merged = true },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);default chart", .merged = true },
        .{ .source = "import paint.*\nchart:=picture(640, 480);default chart;chart=picture(640, 480)", .merged = false },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);default chart;chart=picture(640, 480)", .merged = false },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);default chart;if true then chart=picture(640, 480) end", .merged = false },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);chart=picture(640, 480);default chart", .merged = true },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);default chart;object.append(chart, object.draw((0,0)--(1,1)))", .merged = true },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);default [chart][0]", .merged = false },
        .{ .source = "import paint.*\nexport chart:=picture(640, 480);default chart;for i in 1:2 do x:=i end", .merged = true },
    };
    for (cases) |case| for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?compiler.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, case.source, "choices.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        const choices = try collect(std.testing.allocator, &program);
        defer std.testing.allocator.free(choices);
        try std.testing.expectEqual(@as(usize, if (case.merged) 1 else 2), choices.len);
        if (case.merged) {
            try std.testing.expectEqualStrings("default", choices[0].name);
            try std.testing.expectEqualStrings("chart", choices[0].label);
            try std.testing.expect(choices[0].default);
        } else {
            try std.testing.expectEqualStrings("chart", choices[0].name);
            try std.testing.expect(!choices[0].default);
            try std.testing.expectEqualStrings("default", choices[1].name);
            try std.testing.expectEqualStrings("Default picture", choices[1].label);
        }
    };
}

test "imported and reexported aliases retain the default CLI selector" {
    const compiler = @import("../language/compiler.zig");
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !compiler.ResolvedSource {
            return .{ .name = "library.huak", .source = "import paint.*\nexport chart:=picture(640, 480)" };
        }
    };
    var context: u8 = 0;
    var diagnostic: ?compiler.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\import "library.huak".{chart as figure}
        \\export figure
        \\default figure
    , "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
    defer program.deinit();
    const choices = try collect(std.testing.allocator, &program);
    defer std.testing.allocator.free(choices);
    try std.testing.expectEqual(@as(usize, 1), choices.len);
    try std.testing.expectEqualStrings("default", choices[0].name);
    try std.testing.expectEqualStrings("figure", choices[0].label);
    try std.testing.expect(choices[0].default);
}

test "merging a default alias preserves other explicitly named exports" {
    const compiler = @import("../language/compiler.zig");
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !compiler.ResolvedSource {
            return .{ .name = "library.huak", .source = "import paint.*\nexport chart:=picture(640, 480)" };
        }
    };
    var context: u8 = 0;
    var diagnostic: ?compiler.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\import "library.huak".chart as left
        \\import "library.huak".chart as right
        \\export left,right
        \\default left
    , "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
    defer program.deinit();
    const choices = try collect(std.testing.allocator, &program);
    defer std.testing.allocator.free(choices);
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    try std.testing.expectEqualStrings("default", choices[0].name);
    try std.testing.expectEqualStrings("left", choices[0].label);
    try std.testing.expect(choices[0].default);
    try std.testing.expectEqualStrings("right", choices[1].name);
    try std.testing.expectEqualStrings("right", choices[1].label);
    try std.testing.expect(!choices[1].default);
}
