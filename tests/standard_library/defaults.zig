//! The standard library's default values agree with the native ones.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;

/// The default of `parameter` in the function `function` of bundled `module`.
fn bundledDefault(graph: anytype, module: []const u8, function: []const u8, parameter: []const u8) !@TypeOf(graph.units.items[0].script.statements[0].value.function.params[0].default.?) {
    for (graph.units.items) |unit| {
        if (!std.mem.eql(u8, unit.name, module)) continue;
        for (unit.script.statements) |statement| switch (statement.value) {
            inline .function, .expand_block => |declared| if (std.mem.eql(u8, declared.name, function)) {
                for (declared.params) |declared_parameter| if (std.mem.eql(u8, declared_parameter.name, parameter))
                    return declared_parameter.default orelse error.MissingDefault;
            },
            else => {},
        };
    }
    return error.MissingFunction;
}

fn literal(expression: anytype) !f64 {
    return switch (expression.value) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => error.NotALiteral,
    };
}

test "standard library defaults are the native ones" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diagnostic: ?l.compiler.Diagnostic = null;
    const graph = try l.compiler.parseModules(arena.allocator(), arena.allocator(), "import paint\nimport weave\nimport space", "defaults.huak", .{ .source_parser = .init(&library) }, &diagnostic);
    // A curve tolerance left out is the one native curve operations use.
    for ([_][2][]const u8{ .{ "std/paint.huak", "cut" }, .{ "std/weave.huak", "weave" } }) |site| {
        const quantity = (try bundledDefault(graph, site[0], site[1], "tolerance")).value.quantity;
        const points = try huak.core.units.toPoints(try huak.core.units.applyUnit(try literal(quantity.operand), quantity.unit));
        try t.expectApproxEqRel(huak.core.geometry.curve_tolerance, points, 1e-12);
    }
    // A paper left out is the one flatten_transparency draws on.
    const paper = (huak.core.transparency.Options{}).paper;
    const channels = [_]f64{ paper.r, paper.g, paper.b, paper.a };
    for ([_][]const u8{ "toned", "flat", "shaded" }) |function| {
        const call = (try bundledDefault(graph, "std/space/solids.huak", function, "paper")).value.call;
        try t.expectEqualStrings("rgb", call.name);
        try t.expect(call.args.len == 3 or call.args.len == 4);
        for (call.args, channels[0..call.args.len]) |channel, expected| try t.expectEqual(expected, try literal(channel));
        if (call.args.len == 3) try t.expectEqual(@as(f64, 1), paper.a);
    }
}
