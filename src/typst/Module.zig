//! A Typst module evaluated once and used by many layout requests.
const std = @import("std");
const api = @import("library.zig");
const binding = @import("typst_binding");
const diagnostics = @import("diagnostic.zig");
const c = binding.c;
const a = binding.allocator;

const Module = @This();

library: *api.Library,
handle: ?*c.TypstModule,
/// Borrowed until deinit: the source name, text and origin that locate
/// diagnostics raised inside the module's functions.
name: []const u8,
code: []const u8,
origin: ?api.SourceOrigin = null,
/// The modules this one was evaluated with, borrowed until deinit. An error
/// raised inside their functions while a request uses this module is
/// located in their text.
dependencies: []const *const Module = &.{},
warning_text: ?api.Buffer = null,

/// Evaluates `source` once. The module borrows its name, code, origin and
/// the modules in `source.modules` until deinit; the bindings are borrowed
/// for this call only. An evaluation error becomes the library's last error,
/// located in the text that raised it.
pub fn init(engine: *api.Engine, source: api.ModuleSource) api.Error!Module {
    const library = engine.library;
    library.clearError();
    const context = engine.handle orelse return error.InvalidState;
    if (engine.poisoned.load(.acquire)) return error.InvalidState;
    defer @import("Engine.zig").evict(library);
    if (!try library.supports(c.TYPST_CAP_MODULE_HANDLES)) {
        try library.setError("libtypst does not support module handles");
        return error.Unsupported;
    }
    const handles = try a.alloc(?*const c.TypstModule, source.modules.len);
    defer a.free(handles);
    for (source.modules, handles) |module, *handle| handle.* = try module.native(library);
    var named: std.ArrayList(diagnostics.Source) = .empty;
    defer named.deinit(a);
    try named.append(a, .{ .name = source.name, .text = source.code, .origin = source.origin });
    try appendSources(a, source.modules, &named);
    const dependencies = try a.dupe(*const Module, source.modules);
    errdefer a.free(dependencies);
    var config = std.mem.zeroes(c.TypstEvalOptions);
    config.struct_size = @sizeOf(c.TypstEvalOptions);
    config.bindings = source.bindings.ptr;
    config.binding_count = source.bindings.len;
    config.module_handles = handles.ptr;
    config.module_handle_count = handles.len;
    var output: ?*c.TypstModule = null;
    errdefer library.functions.module_release(output);
    var report: ?*c.TypstDiagnostics = null;
    defer library.functions.diagnostics_release(report);
    const result = library.functions.context_eval(context, binding.str(source.code), binding.str(source.name), &config, &output, &report);
    if (result == c.TYPST_PANIC) engine.poisoned.store(true, .release);
    try library.checkDiagnosed(result, report, named.items);
    const warnings_text = try diagnostics.format(library, report, named.items);
    return .{
        .library = library,
        .handle = output orelse {
            a.free(warnings_text);
            return error.InvalidResult;
        },
        .name = source.name,
        .code = source.code,
        .origin = source.origin,
        .dependencies = dependencies,
        .warning_text = .{ .library = library, .host = warnings_text },
    };
}

pub fn deinit(self: *Module) void {
    self.library.functions.module_release(self.handle);
    self.handle = null;
    a.free(self.dependencies);
    self.dependencies = &.{};
    if (self.warning_text) |*text| text.deinit();
    self.warning_text = null;
}

/// Borrowed until deinit.
pub fn native(self: *const Module, library: *const api.Library) api.Error!*const c.TypstModule {
    if (!self.library.sameInstance(library)) return error.InvalidArgument;
    return self.handle orelse error.InvalidState;
}

/// The text diagnostics raised inside the module's functions are located in.
pub fn diagnosticSource(self: *const Module) diagnostics.Source {
    return .{ .name = self.name, .text = self.code, .origin = self.origin };
}

/// Adds the text of each module and of the modules it was evaluated with,
/// once each, so that a diagnostic raised inside any of them is located in
/// its own text.
pub fn appendSources(allocator: std.mem.Allocator, modules: []const *const Module, sources: *std.ArrayList(diagnostics.Source)) std.mem.Allocator.Error!void {
    for (modules) |module| {
        const known = for (sources.items) |source| {
            if (std.mem.eql(u8, source.name, module.name)) break true;
        } else false;
        if (known) continue;
        try sources.append(allocator, module.diagnosticSource());
        try appendSources(allocator, module.dependencies, sources);
    }
}

/// Warnings raised while the module was evaluated.
pub fn warnings(self: *const Module) api.Error!api.Buffer {
    if (self.handle == null) return error.InvalidState;
    return api.Buffer.copy(self.library, if (self.warning_text) |*text| text.bytes() else "");
}
