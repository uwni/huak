//! Runtime diagnostics: the script call trace, and host and numeric errors.
const std = @import("std");
const Machine = @import("../Machine.zig");
const Error = Machine.Error;
const RuntimeDiagnostic = Machine.RuntimeDiagnostic;
const TraceEntry = Machine.TraceEntry;

pub fn numericFailure(self: *Machine, err: anyerror) Error {
    return switch (err) {
        error.DivisionByZero => self.fail("division by zero", .{}),
        error.Overflow => self.fail("integer overflow", .{}),
        error.DimensionMismatch => self.fail("incompatible quantity dimensions", .{}),
        error.DimensionOverflow => self.fail("quantity dimension exponent overflow", .{}),
        error.InvalidPower => self.fail("quantity power requires compatible integer dimensions", .{}),
        error.TypeMismatch => self.fail("operator requires compatible numeric or vector operands", .{}),
        else => self.fail("arithmetic produced a non-finite value", .{}),
    };
}

pub fn nativeFailure(self: *Machine, err: anyerror) Error {
    if (err == error.RuntimeFailed and self.failure != null) return error.RuntimeFailed;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const message = self.host.errorMessage();
    return nativeFailureMessage(self, err, message);
}

pub fn nativeFailureMessage(self: *Machine, err: anyerror, message: []const u8) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const failure_error = self.fail("native operation failed: {s}", .{@errorName(err)});
    if (failure_error == error.OutOfMemory) return error.OutOfMemory;
    if (self.failure) |*failure| failure.native_message = self.arena.allocator().dupe(u8, message) catch return error.OutOfMemory;
    return error.RuntimeFailed;
}

pub fn captureTrace(self: *Machine, failure: *RuntimeDiagnostic) error{OutOfMemory}!void {
    const origin = if (self.current_module == std.math.maxInt(u32) and self.frames.items.len != 0)
        self.program.functions[self.frames.items[self.frames.items.len - 1].function].module
    else
        self.current_module;
    if (origin < self.program.modules.len) {
        const module_ = self.program.modules[origin];
        failure.diagnostic.setSource(module_.name, module_.source_text);
    }
    const trace = try self.arena.allocator().alloc(TraceEntry, self.frames.items.len);
    for (trace, 0..) |*entry, index| {
        const frame = self.frames.items[self.frames.items.len - 1 - index];
        const span = if (index == 0) self.current_span else self.frames.items[self.frames.items.len - index].call_span;
        const module = if (index == 0) origin else self.frames.items[self.frames.items.len - index].call_module;
        entry.* = .{ .function = self.program.functions[frame.function].name, .module = if (module == std.math.maxInt(u32)) self.program.functions[frame.function].module else module, .span = span };
    }
    failure.trace = trace;
}
