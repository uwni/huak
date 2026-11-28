//! Tests of native domain modules: their exports, aliases, constants and identities.
const std = @import("std");
const source = @import("../source.zig");
const builtins = @import("../builtin.zig");
const lexical = @import("../scope.zig");
const Namespace = builtins.Namespace;
const ModuleGraph = @import("../ModuleGraph.zig");

test "native domain modules export only their signatures and retain aliases" {
    for (std.enums.values(Namespace)) |namespace| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const memory = arena.allocator();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(memory, memory, .{}, null, &diagnostic);
        const input = try memory.print("import {s}\nimport {s} as native\nimport {s}.*\n", .{ namespace.name(), namespace.name(), namespace.name() });
        try graph.root("root.huak", input);
        const root_source = graph.units.items[0];
        const native = graph.units.items[root_source.resolver().namespace(0, "native").?];
        try std.testing.expectEqual(@as(usize, 2), graph.units.items.len);
        try std.testing.expect(root_source.native_namespace == null);
        try std.testing.expectEqual(namespace, native.native_namespace.?);
        try std.testing.expectEqualStrings(namespace.moduleName(), native.name);
        try std.testing.expectEqual(@as(usize, 0), native.imports.items.len);
        try std.testing.expectEqual(root_source.resolver().namespace(0, namespace.name()).?, root_source.resolver().namespace(0, "native").?);
        var count = builtins.constantNames(namespace).len;
        for (builtins.signatures) |signature| {
            if (signature.namespace != namespace) {
                try std.testing.expectEqual(builtins.namespaceLookup(namespace, signature.name) != null, native.public_names.contains(signature.name));
                continue;
            }
            count += 1;
            const exported = native.public_names.get(signature.name).?;
            try std.testing.expectEqual(lexical.Kind.builtin, exported.identity.kind);
            try std.testing.expectEqualStrings(@tagName(signature.id), exported.identity.name);
            try std.testing.expect(lexical.sameIdentity(exported.identity, root_source.resolver().symbolAt(0, signature.name).?.callable.?.identity));
        }
        try std.testing.expectEqual(count, native.public_names.count());
    }
}

test "native selected aliases and reexports preserve the original identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("root.huak", "import math.sin as sine\nimport geometry.circle as disk\nimport pen.pencircle as nib\nexport sine,disk,nib");
    const root_source = graph.units.items[0];
    for ([_]struct { alias: []const u8, original: []const u8 }{
        .{ .alias = "sine", .original = "sin" },
        .{ .alias = "disk", .original = "circle" },
        .{ .alias = "nib", .original = "pencircle" },
    }) |pair| {
        const symbol_value = root_source.public_names.get(pair.alias).?;
        try std.testing.expectEqual(lexical.Kind.builtin, symbol_value.identity.kind);
        try std.testing.expectEqualStrings(pair.original, symbol_value.identity.name);
    }
}

test "native mathematical constants retain data identity and exact values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("root.huak", "import math\nimport math.PI as pi\nexport pi");
    const root_source = graph.units.items[0];
    const native = graph.units.items[root_source.resolver().namespace(0, "math").?];
    for (native.script.statements) |statement| {
        const exported = statement.value.exported;
        if (exported.value) |value| {
            const original = builtins.namespaceConstant(.math, exported.names[0].name).?;
            try std.testing.expectEqual(original.number, value.value.float);
            try std.testing.expectEqual(lexical.Kind.value, native.public_names.get(exported.names[0].name).?.identity.kind);
        }
    }
    try std.testing.expect(lexical.sameIdentity(native.public_names.get("PI").?.identity, root_source.public_names.get("pi").?.identity));
}

test "external resolvers cannot forge a native domain identity before or after its import" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = Namespace.math.moduleName(), .source = "export sneaky:=1" };
        }
    };
    for ([_][]const u8{ "import math\nimport \"spoof\" as external", "import \"spoof\" as external" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var context: u8 = 0;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "reserved native module identity") != null);
    }
}

test "native domains reject members belonging to other responsibilities" {
    for ([_][]const u8{ "import math.print", "import math.picture", "import geometry.pen", "import color.sin", "import animation.draw", "import solver.sin", "import \"std/math.huak\" as obsolete" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
    }
    try std.testing.expect(Namespace.parse("builtin") == null);
}

test "default native namespace syntax does not create an import dependency" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
    try graph.root("default.huak", "angle:=math.sin(math.PI/2)\nink:=color.rgb(0,0,0)\ncurve:=geometry.circle((0,0),1)");
    try std.testing.expectEqual(@as(usize, 1), graph.units.items.len);
}

test "standard namespaces retain canonical native constructor call forms" {
    for ([_]bool{ false, true }) |reversed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        const imports = if (reversed) "import paint.*;import std.*\n" else "import std.*;import paint.*\n";
        const input = try arena.allocator().print("{s}image:=picture with width 10mm height 20mm\nink:=pen with color color.rgb(0,0,0) width 1mm", .{imports});
        try graph.root("constructors.huak", input);
        const unit = graph.units.items[0];
        try std.testing.expect(unit.script.statements[2].value.assignment.value.value == .mixfix_call);
        try std.testing.expect(unit.script.statements[3].value.assignment.value.value == .mixfix_call);
        try std.testing.expect(unit.resolver().callable(0, "picture").member != null);
        try std.testing.expect(unit.resolver().callable(0, "pen").member != null);
        try std.testing.expect(unit.resolver().namespace(0, "picture") != null);
        try std.testing.expect(unit.resolver().namespace(0, "pen") != null);
    }
    for ([_][]const u8{
        "import math as picture;import picture.picture",
        "import picture.picture;import math as picture",
        "import picture as pic;import picture.picture as pic",
    }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, null, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("conflict.huak", input));
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "conflicts with callable") != null);
    }
}
