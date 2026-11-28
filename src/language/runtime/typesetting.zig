//! The Typst engine and its host callbacks: options, layouts, typesetting, Typst modules and huak bindings.
const std = @import("std");
const typst = @import("libtypst");
const Machine = @import("../Machine.zig");
const types = @import("../types.zig");
const typst_bindings = @import("typst_bindings.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const Options = Runtime.Options;
const from = Runtime.from;
const handle = conversions.handle;

/// A typ.module: Typst file content that libtypst evaluated once with the
/// Huak values its code reads. The entry owns the source name, code and
/// origin file name that the evaluated module borrows to locate diagnostics.
pub const TypstModule = struct {
    native: typst.Module,
    code: []const u8,
    name: []const u8,
    origin_name: []const u8,

    pub fn release(self: *TypstModule, gpa: std.mem.Allocator) void {
        self.native.deinit();
        gpa.free(self.code);
        gpa.free(self.name);
        gpa.free(self.origin_name);
    }
};

pub fn copyOptions(gpa: std.mem.Allocator, options: Options) !Options {
    const fonts = try gpa.alloc(typst.FontSource, options.font_sources.len);
    var font_count: usize = 0;
    errdefer {
        for (fonts[0..font_count]) |font| gpa.free(font.data);
        gpa.free(fonts);
    }
    for (fonts, options.font_sources) |*out, in| {
        out.* = .{ .data = try gpa.dupe(u8, in.data) };
        font_count += 1;
    }
    const font_dirs = try gpa.alloc([]const u8, options.font_dirs.len);
    var dir_count: usize = 0;
    errdefer {
        for (font_dirs[0..dir_count]) |dir| gpa.free(dir);
        gpa.free(font_dirs);
    }
    for (font_dirs, options.font_dirs) |*out, in| {
        out.* = try gpa.dupe(u8, in);
        dir_count += 1;
    }
    const inputs = try gpa.alloc(typst.Input, options.inputs.len);
    var input_count: usize = 0;
    errdefer {
        for (inputs[0..input_count]) |input| {
            gpa.free(input.key);
            gpa.free(input.value);
        }
        gpa.free(inputs);
    }
    for (inputs, options.inputs) |*out, in| {
        const key = try gpa.dupe(u8, in.key);
        errdefer gpa.free(key);
        out.* = .{ .key = key, .value = try gpa.dupe(u8, in.value) };
        input_count += 1;
    }
    return .{ .font_sources = fonts, .font_dirs = font_dirs, .system_fonts = options.system_fonts, .use_bundled_fonts = options.use_bundled_fonts, .inputs = inputs };
}

pub fn freeOptions(gpa: std.mem.Allocator, options: Options) void {
    for (options.font_sources) |font| gpa.free(font.data);
    for (options.font_dirs) |dir| gpa.free(dir);
    for (options.inputs) |input| {
        gpa.free(input.key);
        gpa.free(input.value);
    }
    gpa.free(options.font_sources);
    gpa.free(options.font_dirs);
    gpa.free(options.inputs);
}

pub fn releaseLayout(gpa: std.mem.Allocator, layout: *typst.Layout) void {
    layout.deinit();
    gpa.destroy(layout);
}

pub fn captureNative(self: *Runtime) void {
    var buffer = self.backends.typst.lastError() catch return;
    defer buffer.deinit();
    self.setMessage(buffer.bytes());
}

pub fn engineRef(self: *Runtime) !*typst.Engine {
    if (self.shared_engine) |engine| return engine;
    if (self.task_borrow != null) return error.TaskTypographyNotPrepared;
    if (self.engine == null) {
        const options: typst.EngineOptions = .{
            .font_sources = self.options.font_sources,
            .font_dirs = self.options.font_dirs,
            .system_fonts = self.options.system_fonts,
            .use_bundled_fonts = self.options.use_bundled_fonts,
            .inputs = self.options.inputs,
        };
        self.engine = self.backends.typst.createEngineWithOptions(&options) catch |err| {
            captureNative(self);
            return err;
        };
    }
    return &self.engine.?;
}

pub fn typeset(ctx: ?*anyopaque, allocator: std.mem.Allocator, request: Machine.TypstRequest) !Value {
    var values: [1]Value = undefined;
    var detail: Machine.TypstBatchDiagnostic = .{};
    try typesetBatch(ctx, allocator, &.{request}, &values, &detail);
    return values[0];
}

pub fn typesetBatch(ctx: ?*anyopaque, _: std.mem.Allocator, sources: []const Machine.TypstRequest, values: []Value, detail: *Machine.TypstBatchDiagnostic) !void {
    detail.* = .{};
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    if (sources.len != values.len) return error.InvalidArgument;
    self.native_message = "";
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const requests = try scratch.alloc(typst.LayoutRequest, sources.len);
    for (sources, requests) |input, *request| {
        const modules = try requestModules(self, scratch, input.bindings, input.shows);
        // The compiler stored the content-block delimiters with this
        // constant, so code evaluation borrows the program's bytes.
        request.* = .{
            .source = input.source,
            .syntax = .code,
            .bindings = try huakBindings(self, scratch, input.bindings, modules, input.whole),
            .modules = try moduleHandles(self, scratch, modules),
            .show_values = try typst_bindings.encodeShows(scratch, input.shows, modules),
        };
    }
    const metrics = try scratch.alloc(typst.Metrics, sources.len);
    var native_diagnostic: typst.Diagnostic = .{};
    defer native_diagnostic.deinit();
    const result = try retainTextBatch(self, requests, metrics, values, &native_diagnostic);
    detail.completed = result.completed;
    if (result.failure) |err| {
        if (native_diagnostic.text().len != 0) self.setMessage(native_diagnostic.text());
        detail.request_index = native_diagnostic.request_index orelse 0;
        detail.message = self.native_message;
        return err;
    }
}

/// Snapshots the data and lets Typst evaluate the module once, so syntax and
/// evaluation errors are reported where the module is made, and requests use
/// the evaluated module rather than its code.
pub fn makeTypstModule(ctx: ?*anyopaque, _: std.mem.Allocator, module: Machine.TypstModule) !Value {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    self.native_message = "";
    const gpa = self.gpa;
    var temporary: std.heap.ArenaAllocator = .init(gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    // Only modules made before this one exist, so each follows those it binds.
    const bound = try requestModules(self, scratch, module.bindings, &.{});
    const index = self.typst_modules.items.len;
    // Reserve all persistent metadata before acquiring the native owner.
    try self.typst_modules.ensureUnusedCapacity(gpa, 1);
    const entry = try gpa.create(TypstModule);
    errdefer gpa.destroy(entry);
    const code = try gpa.dupe(u8, module.code);
    errdefer gpa.free(code);
    // The path is unique per module, so diagnostics find its text, and its
    // file stem names the Typst module.
    const name = try gpa.print("typ-module/{d}/{s}.typ", .{ index, module.name });
    errdefer gpa.free(name);
    const origin_name = try gpa.dupe(u8, module.origin.name);
    errdefer gpa.free(origin_name);
    const source: typst.ModuleSource = .{
        .code = code,
        .name = name,
        .bindings = try huakBindings(self, scratch, module.bindings, bound, module.whole),
        .modules = try moduleHandles(self, scratch, bound),
        .origin = .{ .name = origin_name, .line = module.origin.line, .column = module.origin.column },
    };
    const engine = try engineRef(self);
    const native = engine.evalModule(source) catch |err| {
        captureNative(self);
        return err;
    };
    entry.* = .{ .native = native, .code = code, .name = name, .origin_name = origin_name };
    self.typst_modules.appendAssumeCapacity(entry);
    return handle(.typst_module, index);
}

/// The modules a request names, in ascending order: those its data binds or
/// it shows. Each module keeps track of the modules it was made with.
fn requestModules(self: *const Runtime, scratch: std.mem.Allocator, bindings: []const Machine.TypstBinding, shows: []const Machine.TypstShow) ![]const usize {
    var found: std.array_hash_map.Auto(usize, void) = .empty;
    for (shows) |show| {
        if (show.value != .handle or show.value.handle.kind != .typst_module) return error.InvalidArgument;
        try addModule(self, scratch, &found, show.value);
    }
    for (bindings) |binding| try addModule(self, scratch, &found, binding.value);
    const modules = try scratch.dupe(usize, found.keys());
    std.mem.sortUnstable(usize, modules, {}, std.sort.asc(usize));
    return modules;
}

fn addModule(self: *const Runtime, scratch: std.mem.Allocator, found: *std.array_hash_map.Auto(usize, void), value: Value) !void {
    if (value != .handle or value.handle.kind != .typst_module) return;
    if (value.handle.index >= self.typst_modules.items.len) return error.InvalidTypstBinding;
    try found.put(scratch, value.handle.index, {});
}

/// Borrowed until the next module is made.
fn moduleHandles(self: *const Runtime, scratch: std.mem.Allocator, modules: []const usize) ![]const *const typst.Module {
    const handles = try scratch.alloc(*const typst.Module, modules.len);
    for (handles, modules) |*item, index| item.* = &self.typst_modules.items[index].native;
    return handles;
}

/// Huak data reaches Typst as the `huak` module, a module value.
fn huakBindings(self: *Runtime, scratch: std.mem.Allocator, bindings: []const Machine.TypstBinding, modules: []const usize, whole: bool) ![]const typst.c.TypstBinding {
    const roots = try typst_bindings.encode(scratch, bindings, self.colors.items, modules, whole);
    if (roots.len != 0 and !try self.backends.typst.supports(typst.c.TYPST_CAP_BINDING_MODULES)) {
        self.native_message = "libtypst does not support module bindings";
        return error.Unsupported;
    }
    return roots;
}

fn retainTextBatch(self: *Runtime, requests: []const typst.LayoutRequest, metrics: []typst.Metrics, values: []Value, diagnostic_detail: *typst.Diagnostic) !struct { completed: usize, failure: ?typst.Error } {
    const gpa = self.gpa;
    // Reserve all persistent metadata before acquiring a native owner; no
    // allocation or partial registration follows a successful layout call.
    const owner = try gpa.create(typst.Layout);
    var registered = false;
    defer if (!registered) gpa.destroy(owner);
    try self.layouts.ensureUnusedCapacity(gpa, 1);
    try self.texts.ensureUnusedCapacity(gpa, requests.len);
    try self.frames.ensureUnusedCapacity(gpa, requests.len);
    const engine = try engineRef(self);
    var result = engine.layoutBatch(requests) catch |err| {
        captureNative(self);
        return err;
    };
    defer result.deinit();
    diagnostic_detail.* = result.takeDiagnostic();
    var completed: usize = 0;
    if (result.takeLayout()) |layout| {
        owner.* = layout;
        registered = true;
        completed = owner.frameCount();
        self.layouts.appendAssumeCapacity(owner);
        for (metrics[0..completed], values[0..completed], 0..) |*metric, *value, index| {
            metric.* = owner.metrics(index) catch unreachable;
            value.* = handle(.text, self.texts.items.len);
            self.texts.appendAssumeCapacity(.{ .layout = owner, .frame = index, .metrics = .{ .width = metric.width, .height = metric.height, .baseline = metric.baseline } });
            self.frames.appendAssumeCapacity(.{ .layout = owner, .index = index });
        }
    }
    return .{ .completed = completed, .failure = result.failure };
}
