//! What each native builtin does to worker safety, fresh ownership, identity observation and Typst use.
const std = @import("std");
const bc = @import("../../bytecode.zig");
const builtin = @import("../../builtin.zig");
const Type = bc.Type;
const effects = @import("../effects.zig");
const Analysis = @import("Analysis.zig");
const Value = effects.Value;
const supportedType = effects.supportedType;
const Budget = effects.Budget;

pub fn builtinResult(self: *Analysis, signature: *const builtin.Signature, arguments: []const Value) Value {
    const id = signature.id;
    for (arguments) |arg| {
        // Unknown elements can be consumed by a fixed read-only signature;
        // dynamic arithmetic and mutable targets need stronger provenance.
        if (!arg.initialized) self.safe = false;
    }
    var result = Value.ordinary(signature.result);
    switch (id) {
        .print => {
            self.safe = false;
            if (arguments.len != 1 or !simpleType(arguments[0].kind)) self.observes_identity = true;
        },
        .solver, .unknown, .equation, .solve, .value => self.safe = false,
        // A script's random stream advances in source order, including
        // calls through aliases and helpers. It cannot be replayed by workers.
        .seed, .random, .randint, .randn => self.safe = false,
        .picture => result.fresh_owner = true,
        .object, .draw, .fill, .filldraw, .label => {
            result.fresh_owner = true;
            if (id == .label or (id == .object and arguments.len != 0 and (arguments[0].kind == .text or arguments[0].kind == .any))) self.uses_typst = true;
        },
        .append => {
            if (arguments.len < 2) {
                self.safe = false;
                return result;
            }
            result = arguments[1];
            if (!arguments[0].fresh_owner or !result.fresh_owner) self.safe = false;
        },
        .canvas, .timeline, .animate, .motion, .object_transform, .object_remove, .object_before, .object_style, .object_visible, .object_clip, .object_reset_clip, .object_opacity => {
            if (arguments.len == 0 or !arguments[0].fresh_owner or (arguments[0].kind != .picture and arguments[0].kind != .object and arguments[0].kind != .any)) self.safe = false;
            // Animation ownership is currently published on the serial path.
            if (id == .animate or id == .motion) self.safe = false;
            if (result.kind == .object and arguments.len != 0) result.fresh_owner = arguments[0].fresh_owner;
            if (id == .object_before and (arguments.len < 2 or !arguments[1].fresh_owner)) self.safe = false;
        },
        // It reads animation tracks, which are published on the serial path.
        .animation_snapshot => {
            self.safe = false;
            result.fresh_owner = true;
        },
        .to_string => {
            if (arguments.len != 1 or !simpleType(arguments[0].kind)) {
                self.safe = false;
                self.observes_identity = true;
            }
        },
        .dict_remove, .object_exclude => self.safe = false,
        .copy => {
            result.kind = arguments[0].kind;
            result.fresh_owner = result.kind.isObject();
            // Collection copies are shallow; copying an object clones its subtree.
            if (!supportedType(result.kind)) self.safe = false;
        },
        .width, .height, .baseline, .anchors => self.uses_typst = true,
        .bounds => {
            if (arguments.len != 0 and arguments[0].kind.isObject()) self.uses_typst = true;
        },
        .outlines, .region, .snapshot, .flatten_transparency => {
            if (id != .region) result.fresh_owner = true;
            if (arguments.len == 0) self.safe = false else switch (arguments[0].kind) {
                .path, .path_or_shape => {},
                .text, .object, .picture => self.uses_typst = true,
                else => self.safe = false,
            }
        },
        .transformed => {
            result.kind = if (arguments.len != 0) arguments[0].kind else .any;
            result.fresh_owner = result.kind.isObject();
        },
        .mapped, .bent => {
            if (arguments.len < 2) self.safe = false else {
                result.kind = arguments[0].kind;
                // Any picture returned by a map is newly owned, including
                // generic wrappers whose input type is checked at runtime.
                result.fresh_owner = result.kind.isObject() or result.kind == .any;
                if (result.kind != .path and result.kind != .path_or_shape and !result.kind.isObject() and result.kind != .any) self.safe = false;
                if (id == .mapped) {
                    if (arguments[1].callable) |function| switch (function) {
                        .bytecode => |index| _ = self.mergeCall(index),
                        .native, .bound => self.safe = false,
                    } else if (arguments[1].kind != .transform) self.safe = false;
                }
            }
        },
        else => {},
    }
    return result;
}

fn simpleType(kind: Type) bool {
    return kind.isScalar() or switch (kind) {
        .unit, .boolean, .string, .vec2, .vec3, .object, .picture => true,
        else => false,
    };
}

test "dictionary reads and shallow copies never create fresh picture provenance" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var program: bc.Program = .{
        .arena = .init(std.testing.allocator),
        .source_text = "",
        .name = "effects",
        .functions = &.{},
        .constants = &.{},
        .parameters = &.{},
        .global_names = &.{},
        .global_types = &.{},
        .readonly_globals = &.{},
    };
    defer program.deinit();
    var budget: Budget = .{};
    var analysis = try Analysis.init(arena.allocator(), std.testing.allocator, &program, &.{}, &budget);
    const dictionary = Value.ordinary(.dict);
    const key = Value.ordinary(.string);
    const contains = builtinResult(&analysis, &builtin.signature(.dict_contains), &.{ dictionary, key });
    try std.testing.expect(analysis.safe);
    try std.testing.expectEqual(Type.boolean, contains.kind);
    try std.testing.expect(!contains.fresh_owner);
    const keys = builtinResult(&analysis, &builtin.signature(.dict_keys), &.{dictionary});
    try std.testing.expect(analysis.safe);
    try std.testing.expectEqual(Type.list, keys.kind);
    try std.testing.expect(!keys.fresh_owner);
    var picture = Value.ordinary(.picture);
    picture.fresh_owner = true;
    const copied_picture = builtinResult(&analysis, &builtin.signature(.copy), &.{picture});
    try std.testing.expectEqual(Type.picture, copied_picture.kind);
    try std.testing.expect(copied_picture.fresh_owner);
    const copied_list = builtinResult(&analysis, &builtin.signature(.copy), &.{Value.ordinary(.list)});
    try std.testing.expectEqual(Type.list, copied_list.kind);
    try std.testing.expect(!copied_list.fresh_owner);
    _ = builtinResult(&analysis, &builtin.signature(.dict_remove), &.{ dictionary, key });
    try std.testing.expect(!analysis.safe);
    try std.testing.expect(!supportedType(Type.record(0)));
    try std.testing.expect(!supportedType(@fromBackingInt(0xffff)));
}
