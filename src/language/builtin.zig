//! Builtin names and signatures shared by the compiler and native runtime.
const std = @import("std");
const Type = @import("types.zig").Type;
const Value = @import("types.zig").Value;

/// Native API ownership. These namespaces do not load source standard modules.
pub const Namespace = enum {
    math,
    geometry,
    projection,
    color,
    gradient,
    pen,
    transform,
    picture,
    object,
    text,
    animation,
    solver,

    pub fn parse(value: []const u8) ?Namespace {
        return std.meta.stringToEnum(Namespace, value);
    }

    pub fn name(self: Namespace) []const u8 {
        return @tagName(self);
    }

    pub fn moduleName(self: Namespace) []const u8 {
        inline for (std.enums.values(Namespace)) |namespace| {
            if (self == namespace) return "<native:" ++ @tagName(namespace) ++ ">";
        }
        unreachable;
    }
};

/// The builtin tables, by domain. A table is named after its namespace
/// (`prelude` for builtins outside every namespace) and declared in exactly
/// one of these files; the table an entry is in is its namespace.
const domains = .{ @import("builtin/values.zig"), @import("builtin/geometry.zig"), @import("builtin/drawing.zig") };

/// The prelude, then each namespace in declaration order.
const order = order: {
    const namespaces = std.enums.values(Namespace);
    var result: [1 + namespaces.len]?Namespace = undefined;
    result[0] = null;
    for (namespaces, 1..) |namespace, index| result[index] = namespace;
    break :order result;
};

fn tableName(comptime namespace: ?Namespace) [:0]const u8 {
    return if (namespace) |value| @tagName(value) else "prelude";
}

fn Domain(comptime namespace: ?Namespace) type {
    var Found: ?type = null;
    inline for (domains) |domain| if (@hasDecl(domain, tableName(namespace))) {
        if (Found != null) @compileError("two builtin tables named " ++ tableName(namespace));
        Found = domain;
    };
    return Found orelse @compileError("no builtin table named " ++ tableName(namespace));
}

fn table(comptime namespace: ?Namespace) @TypeOf(@field(Domain(namespace), tableName(namespace))) {
    return @field(Domain(namespace), tableName(namespace));
}

/// Entry names in table order: the order of `Id` and `signatures`.
const entry_names = collect: {
    @setEvalBranchQuota(10000);
    var count = 0;
    for (order) |namespace| count += std.meta.fieldNames(@TypeOf(table(namespace))).len;
    var result: [count][:0]const u8 = undefined;
    var index = 0;
    for (order) |namespace| for (std.meta.fieldNames(@TypeOf(table(namespace)))) |name| {
        result[index] = name;
        index += 1;
    };
    break :collect result;
};

pub const Id = @Enum(std.math.IntFittingRange(0, entry_names.len - 1), .exhaustive, &entry_names, &std.simd.iota(std.math.IntFittingRange(0, entry_names.len - 1), entry_names.len));
pub const Signature = struct {
    id: Id,
    name: []const u8,
    args: []const Type,
    minimum: usize,
    variadic: ?Type = null,
    parameter_names: []const []const u8 = &.{},
    result: Type,
    namespace: ?Namespace = null,
    implicit: bool = false,

    pub fn acceptsCount(self: Signature, count: usize) bool {
        return count >= self.minimum and (self.variadic != null or count <= self.args.len);
    }
};

fn buildSignature(comptime namespace: ?Namespace, comptime name: [:0]const u8) Signature {
    const entry = @field(table(namespace), name);
    const Parameters = struct {
        const fields_ = std.meta.fieldNames(@TypeOf(entry.args));
        const data: struct { kinds: [fields_.len]Type, names: [fields_.len][]const u8 } = data: {
            var kinds: [fields_.len]Type = undefined;
            var names: [fields_.len][]const u8 = undefined;
            for (fields_, 0..) |parameter, i| {
                kinds[i] = @field(entry.args, parameter);
                names[i] = parameter;
            }
            break :data .{ .kinds = kinds, .names = names };
        };
    };
    return .{
        .id = @field(Id, name),
        .name = if (@hasField(@TypeOf(entry), "name")) entry.name else name,
        .args = &Parameters.data.kinds,
        .minimum = entry.minimum,
        .variadic = if (@hasField(@TypeOf(entry), "variadic")) entry.variadic else null,
        .parameter_names = &Parameters.data.names,
        .result = entry.result,
        .namespace = namespace,
        .implicit = if (@hasField(@TypeOf(entry), "implicit")) entry.implicit else false,
    };
}

/// Table order defines local bytecode IDs and public iteration order.
pub const signatures = build: {
    @setEvalBranchQuota(10000);
    var result: [entry_names.len]Signature = undefined;
    var index = 0;
    for (order) |namespace| for (std.meta.fieldNames(@TypeOf(table(namespace)))) |name| {
        result[index] = buildSignature(namespace, name);
        index += 1;
    };
    break :build result;
};

pub fn lookup(name: []const u8) ?Signature {
    for (signatures) |item| if (std.mem.eql(u8, name, item.name)) return item;
    return null;
}

/// Canonical identities use registry IDs, independent of public names shared
/// by different native namespaces.
pub fn identity(name: []const u8) ?Signature {
    return signature(std.meta.stringToEnum(Id, name) orelse return null);
}

/// Data/diagnostic primitives and primary type constructors form the prelude.
pub fn implicit(name: []const u8) ?Signature {
    const found = lookup(name) orelse return null;
    return if (found.implicit) found else null;
}

pub fn namespaceLookup(namespace: Namespace, name: []const u8) ?Signature {
    for (signatures) |item| if (item.namespace == namespace and std.mem.eql(u8, name, item.name)) return item;
    return null;
}

/// A primary type name can construct values and expose its native operations.
/// An unrelated module alias must never revive the default constructor.
pub fn namespaceConstructor(namespace: Namespace, name: []const u8) ?Signature {
    if (!std.mem.eql(u8, namespace.name(), name)) return null;
    const found = implicit(name) orelse return null;
    return if (found.namespace == namespace) found else null;
}

pub fn constantNames(namespace: Namespace) []const []const u8 {
    return if (namespace == .math) &.{ "PI", "TAU", "E" } else &.{};
}

pub fn namespaceConstant(namespace: Namespace, name: []const u8) ?@import("types.zig").Value {
    if (namespace != .math) return null;
    const value: f64 = if (std.mem.eql(u8, name, "PI")) std.math.pi else if (std.mem.eql(u8, name, "TAU")) 2 * std.math.pi else if (std.mem.eql(u8, name, "E")) std.math.e else return null;
    return .{ .number = value };
}

pub fn signature(id: Id) Signature {
    return signatures[@backingInt(id)];
}

/// A call's arguments by parameter name, one field per parameter of `id`:
/// a required one holds its value (`.omitted` if the call lacks it), an
/// optional one is null when the call leaves it out. Native code reads
/// arguments by these names, so positions stay in the registry.
pub fn Arguments(comptime id: Id) type {
    // Dispatch builds one of these for every builtin in a single evaluation.
    @setEvalBranchQuota(100_000);
    const parameters = signature(id);
    var kinds: [parameters.parameter_names.len]type = undefined;
    for (&kinds, 0..) |*kind, index| kind.* = if (index < parameters.minimum) Value else ?Value;
    const attributes: [kinds.len]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.auto, null, parameters.parameter_names, &kinds, &attributes);
}

/// The positional values a call passes, as `Arguments(id)`.
pub fn arguments(comptime id: Id, values: []const Value) Arguments(id) {
    const parameters = comptime signature(id);
    var result: Arguments(id) = undefined;
    inline for (parameters.parameter_names, 0..) |name, index| {
        const given = index < values.len and values[index] != .omitted;
        @field(result, name) = if (index < parameters.minimum) (if (given) values[index] else .omitted) else if (given) values[index] else null;
    }
    return result;
}

test "arguments are read by parameter name" {
    const call = arguments(.pen, &.{ .{ .number = 1 }, .omitted, .{ .string = "round" } });
    try std.testing.expectEqual(@as(f64, 1), call.paint.number);
    try std.testing.expect(call.width == null and call.join == null and call.tolerance == null);
    try std.testing.expectEqualStrings("round", call.cap.?.string);
    try std.testing.expect(arguments(.pen, &.{}).paint == .omitted);
}

test "native parameter names form a complete unique signature" {
    for (signatures) |item| {
        try std.testing.expectEqualDeep(item, signature(item.id));
        try std.testing.expectEqual(item.args.len, item.parameter_names.len);
        for (item.parameter_names, 0..) |name, index| {
            try std.testing.expect(name.len != 0);
            for (item.parameter_names[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, name, previous));
        }
    }
}
