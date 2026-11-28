const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const ModuleGraph = @import("../ModuleGraph.zig");
const Diagnostic = source.Diagnostic;
const modules = @import("modules.zig");
const groups = @import("groups.zig");
const symbols = @import("symbols.zig");
const lowering = @import("lowering.zig");
const Compiler = @This();
const Environment = symbols.Environment;
const ExpressionDefault = symbols.ExpressionDefault;
const Build = lowering.Build;

environment: *Environment,
allocator: std.mem.Allocator,
diagnostic: *?Diagnostic,
global_names: std.ArrayList([]const u8) = .empty,
global_types: std.ArrayList(Type) = .empty,
readonly_globals: std.ArrayList(bool) = .empty,
declarations: std.ArrayList(?*ast.Stmt) = .empty,
expression_defaults: std.ArrayList(ExpressionDefault) = .empty,
output: std.ArrayList(bc.Function) = .empty,
constants: std.ArrayList(Value) = .empty,
parameters: std.ArrayList(bc.Parameter) = .empty,
exports: std.ArrayList(bc.Export) = .empty,
export_names: std.StringHashMapUnmanaged(void) = .{},
default_output: ?bc.Output = null,
expression_depth: usize = 0,
build: *Build,
global_base: u32,
function_base: u32,
constant_base: u32,

pub fn init(allocator: std.mem.Allocator, diagnostic: *?Diagnostic, unit: *ModuleGraph.Unit, module_index: u32, build: *Build) !Compiler {
    const environment = try build.syntax_allocator.create(Environment);
    environment.* = .{ .unit = unit, .module_index = module_index };
    build.environments[module_index] = environment;
    return .{ .environment = environment, .allocator = allocator, .diagnostic = diagnostic, .build = build, .global_base = @intCast(build.names.items.len), .function_base = @intCast(build.functions.items.len), .constant_base = @intCast(build.constants.items.len) };
}

pub fn fail(self: *Compiler, span: Span, comptime format: []const u8, args: anytype) error{LanguageError} {
    const detail = Diagnostic.set(self.diagnostic, span, format, args);
    detail.setSource(self.environment.unit.name, self.environment.unit.source_text);
    return error.LanguageError;
}
pub fn narrow(self: *Compiler, value: usize, span: Span) !u32 {
    return std.math.cast(u32, value) orelse self.fail(span, "program exceeds bytecode index capacity", .{});
}
pub fn typeOf(self: *Compiler, annotation: ast.Annotation) !Type {
    if (Type.parse(annotation.name)) |kind| return kind;
    if (std.mem.findScalarLast(u8, annotation.name, '.')) |dot| {
        const owner = modules.imported(self, annotation.name[0..dot], annotation.span) orelse return self.fail(annotation.span, "unknown type namespace '{s}'", .{annotation.name[0..dot]});
        const exposed = try modules.importedExport(self, owner, annotation.name[dot + 1 ..], annotation.span);
        if (exposed.target == .record) return Type.record(exposed.target.record);
    } else if (self.environment.unit.resolverAt(annotation.span.start).typeSymbol(self.environment.unit.scopeAt(annotation.span.start), annotation.name)) |member| {
        if (member.module == self.environment.module_index) {
            if (self.environment.records.get(member.name)) |index| return Type.record(index);
        } else {
            const exposed = modules.memberExport(self, member);
            if (exposed.target == .record) return Type.record(exposed.target.record);
        }
    }
    return self.fail(annotation.span, "unknown type '{s}'", .{annotation.name});
}
pub fn typeName(self: *const Compiler, kind: Type) []const u8 {
    if (kind.recordIndex()) |index| if (index < self.build.records.items.len) return self.build.records.items[index].name;
    return kind.name();
}
pub fn require(self: *Compiler, expected: Type, actual: Type, span: Span) !void {
    // An object handle may refer to a picture. The VM checks its concrete
    // kind when assigning the typed slot or entering the function.
    if (expected == .picture and actual == .object) return;
    if (!Type.accepts(expected, actual)) return self.fail(span, "expected {s}, found {s}", .{ self.typeName(expected), self.typeName(actual) });
}
pub fn addConstant(self: *Compiler, value: Value, span: Span) !u32 {
    const index = try self.narrow(self.constants.items.len + self.constant_base, span);
    try self.constants.append(self.allocator, value);
    return index;
}

pub fn recordField(self: *Compiler, kind: Type, name: []const u8, span: Span) !?usize {
    const record_index = kind.recordIndex() orelse return null;
    if (record_index >= self.build.records.items.len) return self.fail(span, "invalid struct type", .{});
    const record = self.build.records.items[record_index];
    for (record.fields, 0..) |field, index| if (std.mem.eql(u8, field.name, name)) return index;
    return self.fail(span, "type {s} has no field '{s}'", .{ record.name, name });
}

pub fn operatorGroup(self: *Compiler, mixed: @FieldType(@FieldType(ast.Expr, "value"), "mixfix_call")) anyerror!u32 {
    if (mixed.qualified) |binding| return groups.groupNamed(self, binding.form.group);
    const name = mixed.operator;
    const leading = mixed.leading;
    if (name.namespace) |alias| {
        const owner = modules.imported(self, alias, name.span) orelse return self.fail(name.span, "unknown module namespace '{s}'", .{alias});
        const exposed = try modules.importedExport(self, owner, name.name, name.span);
        if (exposed.target != .function and exposed.target != .builtin and exposed.target != .record) return self.fail(name.span, "export '{s}' is not a mixfix function", .{name.name});
        if (exportedGroup(exposed, leading)) |group| return group;

        return self.fail(name.span, "function '{s}' has no matching mixfix declaration", .{name.name});
    }
    const resolver_ = self.environment.unit.resolverAt(name.span.start);
    const id = self.environment.unit.scopeAt(name.span.start);
    const call = resolver_.callable(id, name.name);
    if (call.mixfix[@intFromBool(leading)]) |form| return groups.groupNamed(self, form.group);
    if (call.member) |member| if (member.module != self.environment.module_index) {
        const exposed = modules.memberExport(self, member.*);
        if (exportedGroup(exposed, leading)) |group| return group;

        return self.fail(name.span, "function '{s}' has no matching mixfix declaration", .{name.name});
    };
    return self.fail(name.span, "function '{s}' has no matching mixfix declaration", .{name.name});
}

fn exportedGroup(exposed: bc.Export, leading: bool) ?u32 {
    return if (exposed.mixfix[@intFromBool(leading)]) |form| form.group else null;
}
