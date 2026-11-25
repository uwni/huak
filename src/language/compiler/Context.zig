const std = @import("std");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const modules = @import("modules.zig");
const Compiler = @import("Compiler.zig");
const symbols = @import("symbols.zig");
const control = @import("control.zig");
const blocks = @import("blocks.zig");
const typst = @import("typst.zig");
const Context = @This();
const Symbol = symbols.Symbol;
const Loop = control.Loop;
const ReturnBlock = blocks.ReturnBlock;
const Expansion = blocks.Expansion;
const TypstRead = typst.TypstRead;
const Binding = symbols.Binding;

compiler: *Compiler,
code: std.array_list.Managed(bc.Instruction),
locals: std.AutoHashMapUnmanaged(usize, Symbol) = .{},
local_types: std.array_list.Managed(Type),
loops: std.array_list.Managed(*Loop),
entry: bool,
result: Type,
block_depth: usize = 0,
stack_depth: usize = 0,
return_block: ?*ReturnBlock = null,
expansion: ?*Expansion = null,
insertion: ?*Expansion = null,
/// Huak values read by Typst code in this body, checked again once its
/// forward declarations are inferred.
typst_reads: std.ArrayList(TypstRead) = .empty,

pub fn init(compiler: *Compiler, entry: bool, result: Type) Context {
    return .{ .compiler = compiler, .code = .init(compiler.allocator), .local_types = .init(compiler.allocator), .loops = .init(compiler.allocator), .entry = entry, .result = result };
}
pub fn emit(self: *Context, op: bc.Op, a: u32, b: u32, span: Span) !u32 {
    const index = try self.compiler.narrow(self.code.items.len, span);
    const instruction: bc.Instruction = .{ .op = op, .a = a, .b = b, .span = span, .module = self.compiler.environment.module_index };
    const effect = instruction.stackEffect();
    std.debug.assert(self.stack_depth >= effect.consumed);
    self.stack_depth = self.stack_depth - effect.consumed + effect.produced;
    try self.code.append(instruction);
    return index;
}
pub fn patch(self: *Context, instruction: u32, destination: usize) !void {
    self.code.items[instruction].a = try self.compiler.narrow(destination, self.code.items[instruction].span);
}
pub fn constant(self: *Context, value: Value, span: Span) !void {
    const index = try self.compiler.addConstant(value, span);
    _ = try self.emit(.constant, index, 0, span);
}
pub fn resolve(self: *Context, name: []const u8, span: Span) ?Binding {
    const compiler = self.compiler;
    const unit = compiler.environment.unit;
    const readable_ = unit.resolverAt(span.start).readable(unit.scopeAt(span.start), name);
    // The inserted statements share the template's block. Their direct
    // declarations are also visible to its postlude, by declaration identity.
    var active = self.expansion;
    while (active) |scope| : (active = scope.parent) {
        if (scope.definition != unit or span.start < scope.definition_body.start or span.start >= scope.definition_body.end) continue;
        if (readable_) |readable| if (readable == .ordinary and readable.ordinary.scope != 0) break;
        for (scope.environment.unit.headers.scopes[scope.scope].ordinary_names) |declared| {
            if (!std.mem.eql(u8, name, declared.name)) continue;
            var symbol = scope.locals.get(declared.span.start) orelse continue;
            symbol.kind = self.local_types.items[symbol.index];
            symbol.inferable = false;
            symbol.available_after = if (scope.inserted) 0 else std.math.maxInt(usize);
            return .{ .symbol = symbol, .local = true };
        }
    }
    if (readable_) |readable| switch (readable) {
        .ordinary => |ordinary| {
            if (ordinary.module) |module| {
                var expansion = self.expansion;
                while (expansion) |scope| : (expansion = scope.parent) {
                    if (scope.definition.index != module) continue;
                    if (scope.definition_locals.get(ordinary.span.start)) |declared| {
                        var symbol = declared;
                        symbol.kind = self.local_types.items[symbol.index];
                        symbol.inferable = false;
                        symbol.available_after = if (declared.available_after <= scope.insertion_position) 0 else std.math.maxInt(usize);
                        return .{ .symbol = symbol, .local = true };
                    }
                }
                return null;
            }
            if (ordinary.scope == 0) {
                if (compiler.environment.globals.get(name)) |symbol| return .{ .symbol = symbol, .local = false };
            } else if (self.locals.get(ordinary.span.start)) |symbol| {
                return .{ .symbol = symbol, .local = true, .declaration = ordinary.span.start };
            }
        },
        .imported => |target| {
            if (target == .namespace) return null;
            const exposed = modules.memberExport(compiler, target.member);
            const index = exposed.target.global;
            return .{ .symbol = .{ .index = index, .kind = compiler.build.types.items[index], .readonly = true }, .local = false, .module = target.member.module, .initializer = target.member.initializer };
        },
    };
    return null;
}
pub fn temporary(self: *Context, kind: Type, span: Span) !u32 {
    const index = try self.compiler.narrow(self.local_types.items.len, span);
    try self.local_types.append(kind);
    return index;
}
pub fn load(self: *Context, binding: anytype, span: Span) !void {
    if (binding.local and span.start < binding.symbol.available_after)
        return self.compiler.fail(span, "local variable used before its declaration is complete", .{});
    if (binding.module) |module| try self.checkImport(module, binding.initializer, span);
    _ = try self.emit(if (binding.local) .load_local else .load_global, binding.symbol.index, 0, span);
}
pub fn checkImport(self: *Context, module: u32, initializer: ?u32, span: Span) !void {
    if (initializer) |owner| if (owner != module) {
        _ = try self.emit(.check_module, owner, 0, span);
    };
    _ = try self.emit(.check_module, module, 0, span);
}
pub fn store(self: *Context, binding: anytype, span: Span) !void {
    _ = try self.emit(if (binding.local) .store_local else .store_global, binding.symbol.index, 0, span);
}
