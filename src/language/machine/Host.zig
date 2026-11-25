//! Host-owned objects are represented by typed handles. Callbacks may allocate
//! returned strings/sequence views in allocator, which lives until deinit.
//! New collections return ownerless templates (listView for lists), which the
//! VM validates and materializes. Existing nodes may borrow script storage.
//! Callbacks must neither mutate input lists/dictionaries/structs (including
//! their reachable graph) nor retain the operand slice. Borrowed task inputs
//! remain frozen until join. Every callback result is fully validated even
//! when it refers to a previously validated script-owned node.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const Host = @This();
const TypstRequest = Machine.TypstRequest;
const TypstBatchDiagnostic = Machine.TypstBatchDiagnostic;
const TypstModule = Machine.TypstModule;
const Error = Machine.Error;

ptr: ?*anyopaque = null,
vtable: *const VTable = &.{},
tasks: ?Tasks = null,

/// Optional entries describe host capabilities. Callers check availability
/// before invoking a required operation; the context and table are borrowed.
pub inline fn callBuiltin(self: Host, allocator: std.mem.Allocator, id: builtin.Id, operands: []const Value, machine: ?*Machine) anyerror!Value {
    return self.vtable.call_builtin.?(self.ptr, allocator, id, operands, machine);
}
pub inline fn field(self: Host, allocator: std.mem.Allocator, value: Value, name: []const u8) anyerror!Value {
    return self.vtable.field.?(self.ptr, allocator, value, name);
}
pub inline fn binary(self: Host, allocator: std.mem.Allocator, op: bytecode.Op, left: Value, right: Value) anyerror!Value {
    return self.vtable.binary.?(self.ptr, allocator, op, left, right);
}
pub inline fn typeset(self: Host, allocator: std.mem.Allocator, request: TypstRequest) anyerror!Value {
    return self.vtable.typst.?(self.ptr, allocator, request);
}
pub inline fn typesetBatch(self: Host, allocator: std.mem.Allocator, requests: []const TypstRequest, values: []Value, diagnostic: *TypstBatchDiagnostic) anyerror!void {
    return self.vtable.typst_batch.?(self.ptr, allocator, requests, values, diagnostic);
}
pub inline fn typstModule(self: Host, allocator: std.mem.Allocator, module: TypstModule) anyerror!Value {
    return self.vtable.typst_module.?(self.ptr, allocator, module);
}
pub fn errorMessage(self: Host) []const u8 {
    return if (self.vtable.error_message) |message| message(self.ptr) else "";
}

pub const VTable = struct {
    /// Arguments are borrowed until the first reentrant call. A host that
    /// invokes a script function must copy the values it still needs first.
    call_builtin: ?*const fn (?*anyopaque, std.mem.Allocator, builtin.Id, []const Value, ?*Machine) anyerror!Value = null,
    field: ?*const fn (?*anyopaque, std.mem.Allocator, Value, []const u8) anyerror!Value = null,
    binary: ?*const fn (?*anyopaque, std.mem.Allocator, bytecode.Op, Value, Value) anyerror!Value = null,
    typst: ?*const fn (?*anyopaque, std.mem.Allocator, TypstRequest) anyerror!Value = null,
    /// Success initializes every output. Errors initialize only the diagnostic's
    /// completed prefix. Neither descriptor slice may be retained by the host.
    typst_batch: ?*const fn (?*anyopaque, std.mem.Allocator, []const TypstRequest, []Value, *TypstBatchDiagnostic) anyerror!void = null,
    /// Makes a typ.module from the content of a Typst file, snapshotting
    /// the bindings its code reads. Inputs are borrowed.
    typst_module: ?*const fn (?*anyopaque, std.mem.Allocator, TypstModule) anyerror!Value = null,
    error_message: ?*const fn (?*anyopaque) []const u8 = null,
};

/// Scheduling has its own implementation state and lifetime.
pub const Tasks = struct {
    ptr: ?*anyopaque = null,
    vtable: *const Tasks.VTable,

    pub inline fn dispatch(self: Tasks, machine: *Machine, region: *const bytecode.TaskRegion) Error!bool {
        return self.vtable.dispatch(self.ptr, machine, region);
    }

    pub const VTable = struct {
        /// False leaves execution untouched and uses the ordinary instruction loop.
        dispatch: *const fn (?*anyopaque, *Machine, *const bytecode.TaskRegion) Error!bool,
    };
};
