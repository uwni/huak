//! Long-lived native contexts shared by independent typography jobs.
const std = @import("std");
const api = @import("library.zig");
const binding = @import("typst_binding");
const diagnostics = @import("diagnostic.zig");
const c = binding.c;
const a = binding.allocator;

const Engine = @This();

library: *api.Library,
handle: ?*c.TypstContext,
poisoned: std.atomic.Value(bool) = .init(false),

pub fn init(library: *api.Library, options: api.EngineOptions) api.Error!Engine {
    return shared(library, options, false);
}

/// For requests whose result does not depend on fonts, files or inputs, such
/// as PDF page import. Borrows the current context whatever its configuration
/// and creates the default one only when there is none, so the configuration
/// cached for typesetting stays in place.
pub fn initAny(library: *api.Library) api.Error!Engine {
    return shared(library, .{}, true);
}

fn shared(library: *api.Library, options: api.EngineOptions, any_configuration: bool) api.Error!Engine {
    const key = fingerprint(options);
    std.Io.Threaded.mutexLockUncancelable(&library.resources_mutex);
    defer std.Io.Threaded.mutexUnlock(&library.resources_mutex);
    if (library.shared_context == null or (!any_configuration and library.shared_options != key)) {
        const created = try createContext(library, options);
        library.functions.context_release(library.shared_context);
        library.shared_context = created;
        library.shared_options = key;
    }
    library.functions.context_retain(library.shared_context);
    return .{ .library = library, .handle = library.shared_context };
}

/// Identifies a complete configuration; each field is length-prefixed.
fn fingerprint(options: api.EngineOptions) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&.{ @intFromBool(options.system_fonts), @intFromBool(options.use_bundled_fonts) });
    hasher.update(std.mem.asBytes(&options.font_sources.len));
    for (options.font_sources) |font| bytes(&hasher, font.data);
    hasher.update(std.mem.asBytes(&options.font_dirs.len));
    for (options.font_dirs) |dir| bytes(&hasher, dir);
    hasher.update(std.mem.asBytes(&options.inputs.len));
    for (options.inputs) |input| {
        bytes(&hasher, input.key);
        bytes(&hasher, input.value);
    }
    return hasher.final();
}

fn bytes(hasher: *std.hash.Wyhash, data: []const u8) void {
    hasher.update(std.mem.asBytes(&data.len));
    hasher.update(data);
}
pub fn deinit(self: *Engine) void {
    self.library.functions.context_release(self.handle);
    self.handle = null;
}
pub fn compile(self: *Engine, source: []const u8) api.Error!api.Document {
    self.library.clearError();
    const context = self.handle orelse return error.InvalidState;
    if (self.poisoned.load(.acquire)) return error.InvalidState;
    defer evict(self.library);
    var output: ?*c.TypstDocument = null;
    errdefer self.library.functions.document_release(output);
    var report: ?*c.TypstDiagnostics = null;
    defer self.library.functions.diagnostics_release(report);
    const result = self.library.functions.context_compile(context, binding.str(source), binding.str("source"), &output, &report);
    if (result == c.TYPST_PANIC) self.poisoned.store(true, .release);
    const sources = [_]diagnostics.Source{.{ .name = "source", .text = source }};
    try self.library.checkDiagnosed(result, report, &sources);
    const warnings = try diagnostics.format(self.library, report, &sources);
    errdefer a.free(warnings);
    var document = api.Document.fromOwned(self.library, output orelse return error.InvalidResult);
    document.warning_text = .{ .library = self.library, .host = warnings };
    return document;
}
pub fn layoutContent(self: *Engine, requests: []const api.LayoutRequest, metrics: []api.Metrics, diagnostic: ?*api.Diagnostic) api.Error!api.Layout {
    return @import("layout.zig").layoutContent(self, requests, metrics, diagnostic);
}
pub fn layoutBatch(self: *Engine, requests: []const api.LayoutRequest) api.Error!api.BatchResult {
    return @import("layout.zig").layoutBatch(self, requests);
}
/// Evaluates Typst code once into a module that later requests use.
pub fn evalModule(self: *Engine, source: api.ModuleSource) api.Error!api.Module {
    return api.Module.init(self, source);
}

fn createContext(library: *api.Library, options: api.EngineOptions) api.Error!*c.TypstContext {
    const fonts = try a.alloc(c.TypstFontSource, options.font_sources.len);
    defer a.free(fonts);
    for (fonts, options.font_sources) |*font, source| font.* = .{ .data = binding.binary(source.data) };
    const dirs = try a.alloc(c.TypstStr, options.font_dirs.len);
    defer a.free(dirs);
    for (dirs, options.font_dirs) |*dir, path| dir.* = binding.str(path);
    const inputs = try inputsJson(library, options.inputs);
    defer a.free(inputs);
    var config = std.mem.zeroes(c.TypstContextOptions);
    config.struct_size = @sizeOf(c.TypstContextOptions);
    config.flags = c.TYPST_CONTEXT_DISABLE_PLUGINS;
    if (!options.use_bundled_fonts) config.flags |= c.TYPST_CONTEXT_NO_BUILTIN_FONTS;
    if (options.system_fonts) config.flags |= c.TYPST_CONTEXT_SYSTEM_FONTS;
    config.fonts = fonts.ptr;
    config.font_count = fonts.len;
    config.font_dirs = dirs.ptr;
    config.font_dir_count = dirs.len;
    config.inputs_json = binding.str(inputs);
    var output: ?*c.TypstContext = null;
    errdefer library.functions.context_release(output);
    var report: ?*c.TypstDiagnostics = null;
    defer library.functions.diagnostics_release(report);
    const result = library.functions.context_create(&config, &output, &report);
    try library.check(result, report);
    return output orelse error.InvalidResult;
}

fn inputsJson(library: *api.Library, inputs: []const api.Input) api.Error![]u8 {
    for (inputs, 0..) |input, index| {
        if (input.key.len == 0) {
            try library.setError("input keys must be nonempty");
            return error.InvalidArgument;
        }
        if (!std.unicode.utf8ValidateSlice(input.key) or !std.unicode.utf8ValidateSlice(input.value)) {
            try library.setError("input keys and values must contain valid UTF-8");
            return error.InvalidUtf8;
        }
        for (inputs[0..index]) |prior| if (std.mem.eql(u8, prior.key, input.key)) {
            try library.setError("input keys must be unique");
            return error.InvalidArgument;
        };
    }
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    for (inputs) |input| {
        json.objectField(input.key) catch return error.OutOfMemory;
        json.write(input.value) catch return error.OutOfMemory;
    }
    json.endObject() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

pub fn evict(library: *api.Library) void {
    // Preserve Huak's existing cache age policy, once per completed batch.
    _ = library.functions.cache_evict(10);
}
