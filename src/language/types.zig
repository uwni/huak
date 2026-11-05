//! Values exchanged between the bytecode VM and the drawing runtime.
const std = @import("std");
const g = @import("../drawing/geometry.zig");
pub const units = @import("../drawing/units.zig");

pub const Type = enum(u32) {
    any,
    unit,
    int,
    number,
    length,
    angle,
    quantity,
    scalar,
    boolean,
    string,
    pair,
    list,
    path,
    color,
    pen,
    transform,
    solver,
    variable,
    linear,
    solution,
    text,
    picture,
    dict,
    function,
    measure,
    object,
    _,

    pub const record_base: u32 = 0x10000;

    pub fn record(index: u32) Type {
        return @fromBackingInt(@intCast(record_base + index));
    }

    pub fn isRecord(self: Type) bool {
        return @backingInt(self) >= record_base;
    }

    pub fn recordIndex(self: Type) ?u32 {
        return if (self.isRecord()) @backingInt(self) - record_base else null;
    }

    pub fn name(self: Type) []const u8 {
        const info = @typeInfo(Type).@"enum";
        inline for (info.field_names, info.field_values) |field_name, value| {
            if (@backingInt(self) == value) return field_name;
        }
        return if (self.isRecord()) "struct" else "unknown";
    }

    pub fn parse(text: []const u8) ?Type {
        if (std.mem.eql(u8, text, "float") or std.mem.eql(u8, text, "numeric")) return .number;
        if (std.mem.eql(u8, text, "bool")) return .boolean;
        if (std.mem.eql(u8, text, "void")) return .unit;
        return std.meta.stringToEnum(Type, text);
    }

    /// Read-only native fields shared by type checking and worker analysis.
    pub fn fieldType(self: Type, field: []const u8) ?Type {
        const Field = struct { owner: Type, name: []const u8, kind: Type };
        const fields = [_]Field{
            .{ .owner = .pair, .name = "x", .kind = .scalar },
            .{ .owner = .pair, .name = "y", .kind = .scalar },
            .{ .owner = .text, .name = "width", .kind = .length },
            .{ .owner = .text, .name = "height", .kind = .length },
            .{ .owner = .text, .name = "baseline", .kind = .length },
            .{ .owner = .picture, .name = "width", .kind = .length },
            .{ .owner = .picture, .name = "height", .kind = .length },
            .{ .owner = .object, .name = "kind", .kind = .string },
            .{ .owner = .object, .name = "paths", .kind = .list },
            .{ .owner = .object, .name = "children", .kind = .list },
            .{ .owner = .object, .name = "animated", .kind = .boolean },
            .{ .owner = .object, .name = "visible", .kind = .boolean },
            .{ .owner = .object, .name = "transform", .kind = .transform },
            .{ .owner = .object, .name = "parent", .kind = .any },
            .{ .owner = .object, .name = "fill", .kind = .any },
            .{ .owner = .object, .name = "pen", .kind = .any },
            .{ .owner = .solution, .name = "status", .kind = .string },
            .{ .owner = .solution, .name = "rank", .kind = .int },
            .{ .owner = .measure, .name = "length", .kind = .length },
            .{ .owner = .measure, .name = "contours", .kind = .int },
            .{ .owner = .measure, .name = "curves", .kind = .list },
        };
        for (fields) |entry| if ((self == entry.owner or (self == .picture and entry.owner == .object)) and std.mem.eql(u8, field, entry.name)) return entry.kind;
        return null;
    }

    pub fn accepts(expected: Type, actual: Type) bool {
        return expected == .any or actual == .any or expected == actual or
            (expected == .object and actual == .picture) or
            (expected == .number and actual == .int) or
            (expected == .scalar and actual.isScalar()) or
            (actual == .scalar and expected.isScalar()) or
            (expected == .quantity and (actual == .length or actual == .angle)) or
            ((expected == .length or expected == .angle) and (actual == .number or actual == .int));
    }
    pub fn isScalar(self: Type) bool {
        return switch (self) {
            .int, .number, .length, .angle, .quantity, .scalar => true,
            else => false,
        };
    }

    pub fn isObject(self: Type) bool {
        return self == .object or self == .picture;
    }
};

pub const Pair = struct {
    x: f64,
    y: f64,
    dimension: units.Dimension = .scalar,
    pub const zero: Pair = .{ .x = 0, .y = 0 };
    pub fn isFinite(self: Pair) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y);
    }
    pub fn scale(self: Pair, value: f64) Pair {
        return .{ .x = self.x * value, .y = self.y * value, .dimension = self.dimension };
    }
    pub fn component(self: Pair, value: f64) Value {
        return fromQuantity(.{ .value = value, .dimension = self.dimension });
    }
    pub fn nativePoint(self: Pair) units.Error!g.Point {
        if (!self.isFinite()) return error.NonFinite;
        if (self.dimension.eql(.scalar)) return .{ .x = self.x, .y = self.y };
        return .{ .x = try units.toPoints(.{ .value = self.x, .dimension = self.dimension }), .y = try units.toPoints(.{ .value = self.y, .dimension = self.dimension }) };
    }
    pub fn fromPoint(point: g.Point) Pair {
        return .{ .x = units.fromPoints(point.x).value, .y = units.fromPoints(point.y).value, .dimension = .distance };
    }
};

/// A drawing instance in a stable scene owner, valid for its execution lifetime.
/// Command storage can grow without changing this identity. No allocation is needed.
pub const Object = struct { owner: *const anyopaque, index: u32, kind: enum(u32) { object = @backingInt(Type.object), picture = @backingInt(Type.picture) } = .object };
pub const Handle = struct { kind: Type, index: usize };
/// Explicit partial application stores values, never a captured lexical scope.
pub const Function = union(enum) {
    bytecode: u32,
    native: u32,
    bound: *Bound,

    pub const Target = union(enum) { bytecode: u32, native: u32 };
    pub const Bound = struct {
        owner: ?*const Ownership = null,
        target: Target,
        arguments: []Value,
        names: []const ?[]const u8,
    };
    pub fn target(self: Function) Target {
        return switch (self) {
            .bytecode => |index| .{ .bytecode = index },
            .native => |index| .{ .native = index },
            .bound => |value| value.target,
        };
    }
};
/// Stable VM ownership identity. The byte gives each allocation a distinct address.
pub const Ownership = struct { marker: u8 = 0 };
/// One list value. Read-only views borrow their contents; mutable storage has
/// a stable execution owner and is shared by reference when the value is copied.
pub const List = union(enum) {
    view: []const Value,
    owned: *Owned,

    pub const Owned = struct {
        owner: ?*const Ownership = null,
        values: std.ArrayList(Value) = .empty,
    };

    pub fn items(self: List) []const Value {
        return switch (self) {
            .view => |values| values,
            .owned => |storage| storage.values.items,
        };
    }
};
/// Immutable templates have no owner. The VM copies their complete graph at
/// script ownership boundaries; runtime copies share the same mutable node.
pub const Dict = struct {
    owner: ?*const Ownership = null,
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
};
pub const Record = struct {
    owner: ?*const Ownership = null,
    kind: Type,
    fields: []Value,
};
pub const Value = union(enum) {
    unit,
    /// Compiler-only missing optional builtin slot. It must never escape into
    /// script data; unit remains an explicit, distinct argument value.
    omitted,
    int: i64,
    number: f64,
    quantity: units.Quantity,
    boolean: bool,
    string: []const u8,
    pair: Pair,
    list: List,
    dict: *Dict,
    record: *Record,
    handle: Handle,
    function: Function,
    object: Object,

    pub fn valueType(self: Value) Type {
        return switch (self) {
            .unit => .unit,
            .omitted => .unit,
            .int => .int,
            .number => .number,
            .quantity => |q| if (q.dimension.eql(.distance)) .length else if (q.dimension.eql(.rotation)) .angle else .quantity,
            .boolean => .boolean,
            .string => .string,
            .pair => .pair,
            .list => .list,
            .dict => .dict,
            .record => |record_value| record_value.kind,
            .handle => |h| h.kind,
            .function => .function,
            .object => |object| @fromBackingInt(@backingInt(object.kind)),
        };
    }
};

/// Borrowed contiguous contents for native adapters and read-only consumers.
pub fn sequence(value: Value) ?[]const Value {
    return switch (value) {
        .list => |list| list.items(),
        else => null,
    };
}

/// Native adapters and Program constants borrow immutable list contents until
/// the VM gives the list execution-owned storage at a script ownership boundary.
pub fn listView(items: []const Value) Value {
    return .{ .list = .{ .view = items } };
}

test "list storage fits the existing geometry value payload" {
    try std.testing.expect(@sizeOf(Object) <= @sizeOf(Pair));
    try std.testing.expect(@sizeOf(List) <= @sizeOf(Pair));
    try std.testing.expect(@sizeOf(*Dict) <= @sizeOf(Pair));
    try std.testing.expect(@sizeOf(*Record) <= @sizeOf(Pair));
}

test "nominal struct types preserve builtin IDs and safe names" {
    try std.testing.expectEqual(@as(u32, 21), @backingInt(Type.picture));
    try std.testing.expectEqual(@as(u32, 22), @backingInt(Type.dict));
    const first = Type.record(0);
    const second = Type.record(1);
    try std.testing.expectEqual(@as(u32, 0x10000), @backingInt(first));
    try std.testing.expect(first.isRecord());
    try std.testing.expectEqual(@as(?u32, 1), second.recordIndex());
    try std.testing.expect(Type.int.recordIndex() == null);
    try std.testing.expect(Type.accepts(first, first));
    try std.testing.expect(!Type.accepts(first, second));
    try std.testing.expectEqualStrings("struct", first.name());
    try std.testing.expectEqualStrings("dict", Type.dict.name());
    try std.testing.expectEqualStrings("unknown", @as(Type, @fromBackingInt(@intCast(0xffff))).name());
}

pub fn fromQuantity(quantity: units.Quantity) Value {
    return if (quantity.dimension.eql(.scalar)) .{ .number = quantity.value } else .{ .quantity = quantity };
}
pub fn asQuantity(value: Value) error{TypeMismatch}!units.Quantity {
    return switch (value) {
        .int => |v| .{ .value = @floatFromInt(v) },
        .number => |v| .{ .value = v },
        .quantity => |v| v,
        else => error.TypeMismatch,
    };
}
