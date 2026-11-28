//! Bytecode program builders and a Typst host that records its requests, for the VM tests.
const std = @import("std");
const units = @import("../../drawing/units.zig");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Type = types.Type;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const Host = @import("Host.zig");
const TypstBinding = Machine.TypstBinding;
const TypstShow = Machine.TypstShow;
const TypstModule = Machine.TypstModule;
const TypstRequest = Machine.TypstRequest;
const TypstBatchDiagnostic = Machine.TypstBatchDiagnostic;

pub fn testProgram(functions: []const bytecode.Function, constants: []const Value, names: []const []const u8, global_types: []const Type) !bytecode.Program {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const readonly = try arena.allocator().alloc(bool, names.len);
    @memset(readonly, false);
    return .{ .arena = arena, .source_text = "", .name = "vm-test", .functions = functions, .constants = constants, .parameters = &.{}, .global_names = names, .global_types = global_types, .readonly_globals = readonly };
}

pub fn ins(op: bytecode.Op, a: u32) I {
    return .{ .op = op, .a = a };
}

/// Pure VM probes check batching and sequencing, independently of native FFI
/// acceptance.
pub const TypstBatchProbe = struct {
    single_calls: usize = 0,
    batch_sizes: [256]usize = @splat(0),
    batch_count: usize = 0,
    seen: [256][]const u8 = undefined,
    captures: [256][]const TypstBinding = undefined,
    shows: [256][]const TypstShow = undefined,
    whole: [256]bool = @splat(false),
    modules: [16]TypstModule = undefined,
    module_count: usize = 0,
    seen_count: usize = 0,
    fields: usize = 0,
    effects: usize = 0,
    fatal_index: ?usize = null,
    message_storage: [64]u8 = @splat(0),
    message_length: usize = 0,

    fn from(context: ?*anyopaque) *TypstBatchProbe {
        return @ptrCast(@alignCast(context.?));
    }

    pub fn value(self: *TypstBatchProbe, allocator: std.mem.Allocator, request: TypstRequest) !Value {
        const text = request.source;
        const index = self.seen_count;
        self.seen[index] = text;
        self.captures[index] = try allocator.dupe(TypstBinding, request.bindings);
        self.shows[index] = try allocator.dupe(TypstShow, request.shows);
        self.whole[index] = request.whole;
        self.seen_count += 1;
        if (std.mem.indexOf(u8, text, "FAIL") != null) return error.TypesetFailed;
        return .{ .handle = .{ .kind = .text, .index = index } };
    }

    fn one(context: ?*anyopaque, allocator: std.mem.Allocator, request: TypstRequest) !Value {
        const self = from(context);
        self.single_calls += 1;
        return self.value(allocator, request) catch |err| {
            self.message_length = @min(request.source.len, self.message_storage.len);
            @memcpy(self.message_storage[0..self.message_length], request.source[0..self.message_length]);
            return err;
        };
    }

    pub fn batch(context: ?*anyopaque, allocator: std.mem.Allocator, requests: []const TypstRequest, values: []Value, diagnostic: *TypstBatchDiagnostic) !void {
        const self = from(context);
        self.batch_sizes[self.batch_count] = requests.len;
        self.batch_count += 1;
        if (self.fatal_index) |index| {
            diagnostic.* = .{ .request_index = index, .message = "fatal native probe" };
            return error.TypstPanic;
        }
        for (requests, values, 0..) |request, *result, index| {
            const text = request.source;
            result.* = self.value(allocator, request) catch |err| {
                const length = @min(text.len, self.message_storage.len);
                @memcpy(self.message_storage[0..length], text[0..length]);
                diagnostic.* = .{ .completed = index, .request_index = index, .message = self.message_storage[0..length] };
                return err;
            };
        }
    }

    fn makeModule(context: ?*anyopaque, allocator: std.mem.Allocator, module: TypstModule) !Value {
        const self = from(context);
        self.modules[self.module_count] = .{ .code = module.code, .name = try allocator.dupe(u8, module.name), .bindings = try allocator.dupe(TypstBinding, module.bindings), .whole = module.whole, .origin = module.origin };
        self.module_count += 1;
        return .{ .handle = .{ .kind = .typst_module, .index = self.module_count - 1 } };
    }

    pub fn field(context: ?*anyopaque, _: std.mem.Allocator, text: Value, _: []const u8) !Value {
        from(context).fields += 1;
        return .{ .quantity = units.fromPoints(@floatFromInt(text.handle.index + 1)) };
    }

    fn effect(context: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
        from(context).effects += 1;
        return .unit;
    }

    const host_vtable: Host.VTable = .{ .typst = one, .typstBatch = batch, .typstModule = makeModule, .field = field, .callBuiltin = effect, .errorMessage = message };
    const single_host_vtable = blk: {
        var table = host_vtable;
        table.typstBatch = null;
        break :blk table;
    };

    pub fn host(self: *TypstBatchProbe, batched: bool) Host {
        return .{ .ptr = self, .vtable = if (batched) &host_vtable else &single_host_vtable };
    }

    pub fn message(context: ?*anyopaque) []const u8 {
        const self = from(context);
        return self.message_storage[0..self.message_length];
    }

    pub fn compile(input: []const u8, optimize: bool) !bytecode.Program {
        const compiler = @import("../compiler.zig");
        var diagnostic: ?source.Diagnostic = null;
        return compiler.compile(std.testing.allocator, input, "typst-batch-vm.huak", .{ .optimize = optimize, .source_parser = @import("../Parser.zig").TestSourceParser.parser }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
            return err;
        };
    }
};
