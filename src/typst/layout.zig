//! Batch owners over independently retained native layouts.
const std = @import("std");
const api = @import("library.zig");
const binding = @import("typst_binding");
const diagnostics = @import("diagnostic.zig");
const c = binding.c;
const a = binding.allocator;

pub const FrameBatch = struct {
    frames: []*c.TypstLayout,
    measurements: []api.Metrics,
    warning_text: []u8,
};
pub const Layout = struct {
    library: *api.Library,
    handle: ?*FrameBatch,

    pub fn frameCount(self: *const Layout) usize {
        return if (self.handle) |batch| batch.frames.len else 0;
    }
    pub fn frame(self: *const Layout, index: usize) api.Error!FrameRef {
        const batch = self.handle orelse return error.InvalidState;
        if (index >= batch.frames.len) return error.InvalidArgument;
        return .{ .layout = self, .index = index };
    }
    pub fn metrics(self: *const Layout, index: usize) api.Error!api.Metrics {
        const batch = self.handle orelse return error.InvalidState;
        if (index >= batch.measurements.len) return error.InvalidArgument;
        return batch.measurements[index];
    }
    pub fn warnings(self: *const Layout) api.Error!api.Buffer {
        return api.Buffer.copy(self.library, (self.handle orelse return error.InvalidState).warning_text);
    }
    /// Conservative frame-local bounds, including native ink beyond metrics.
    pub fn bounds(self: *const Layout, index: usize) api.Error![2]c.TypstPoint {
        const reference = try self.frame(index);
        var result: [2]c.TypstPoint = undefined;
        try self.library.check(self.library.functions.layout_bounds(try reference.nativeLayout(self.library), &result), null);
        return result;
    }
    /// Labeled elements in document order, in frame-local y-down points.
    /// Borrowed until this Layout releases the request's owner.
    pub fn labels(self: *const Layout, index: usize) api.Error![]const c.TypstLabeledElement {
        const reference = try self.frame(index);
        if (!try self.library.supports(c.TYPST_CAP_LAYOUT_LABELS)) {
            try self.library.setError("libtypst does not report labeled elements");
            return error.Unsupported;
        }
        var view: c.TypstLabelView = undefined;
        try self.library.check(self.library.functions.layout_labels(try reference.nativeLayout(self.library), &view), null);
        return if (view.element_count == 0) &.{} else view.elements[0..view.element_count];
    }
    pub fn deinit(self: *Layout) void {
        if (self.handle) |batch| {
            for (batch.frames) |owner| self.library.functions.layout_release(owner);
            a.free(batch.frames);
            a.free(batch.measurements);
            a.free(batch.warning_text);
            a.destroy(batch);
        }
        self.handle = null;
    }
};

/// A completed native batch. On ordinary failure, layout owns only the
/// successful prefix. A panic never publishes a prefix for reuse.
pub const BatchResult = struct {
    layout: ?Layout = null,
    diagnostic: api.Diagnostic = .{},
    failure: ?api.Error = null,

    pub fn takeLayout(self: *BatchResult) ?Layout {
        const value = self.layout;
        self.layout = null;
        return value;
    }
    pub fn takeDiagnostic(self: *BatchResult) api.Diagnostic {
        const value = self.diagnostic;
        self.diagnostic = .{};
        return value;
    }
    pub fn deinit(self: *BatchResult) void {
        if (self.layout) |*value| value.deinit();
        self.diagnostic.deinit();
        self.* = .{};
    }
};
pub const FrameRef = struct {
    layout: *const Layout,
    index: usize,

    /// Borrowed until the parent Layout releases this request's owner.
    pub fn nativeLayout(self: FrameRef, library: *const api.Library) api.Error!*const c.TypstLayout {
        if (!self.layout.library.sameInstance(library)) return error.InvalidArgument;
        const batch = self.layout.handle orelse return error.InvalidState;
        if (self.index >= batch.frames.len) return error.InvalidArgument;
        return batch.frames[self.index];
    }
};

/// Formats native diagnostics against the texts the request names, including
/// those of the modules its modules were evaluated with.
fn describe(library: *api.Library, report: ?*const c.TypstDiagnostics, request: api.LayoutRequest) api.Error![]u8 {
    var named: std.ArrayList(diagnostics.Source) = .empty;
    defer named.deinit(a);
    try named.ensureTotalCapacity(a, 2 + 2 * request.templates.len + request.modules.len);
    named.appendAssumeCapacity(.{ .name = "source", .text = request.source });
    named.appendAssumeCapacity(.{ .name = "preamble", .text = request.preamble });
    for (request.templates) |template| {
        named.appendAssumeCapacity(.{ .name = template.name, .text = template.code, .origin = template.origin });
        named.appendAssumeCapacity(.{ .name = template.setup_name, .text = template.setup });
    }
    try api.Module.appendSources(a, request.modules, &named);
    return diagnostics.format(library, report, named.items);
}

/// The capability a request needs beyond plain layout, if any is missing.
/// Value trees are not read here: the library validates them, and reports a
/// value kind it does not know as an invalid argument.
fn unsupported(library: *api.Library, requests: []const api.LayoutRequest) api.Error!?[]const u8 {
    var bindings = false;
    var templates = false;
    var modules = false;
    var show_values = false;
    for (requests) |request| {
        bindings = bindings or request.bindings.len != 0;
        templates = templates or request.templates.len != 0;
        modules = modules or request.modules.len != 0;
        show_values = show_values or request.show_values.len != 0;
    }
    if (bindings and !try library.supports(c.TYPST_CAP_LAYOUT_BINDINGS)) return "libtypst does not support request-local layout bindings";
    if (templates and !try library.supports(c.TYPST_CAP_LAYOUT_TEMPLATES)) return "libtypst does not support layout templates";
    if (modules and !try library.supports(c.TYPST_CAP_MODULE_HANDLES)) return "libtypst does not support module handles";
    if (show_values and !try library.supports(c.TYPST_CAP_SHOW_VALUES)) return "libtypst does not support show rule values";
    return null;
}

pub fn layoutContent(engine: *api.Engine, requests: []const api.LayoutRequest, metrics: []api.Metrics, detail: ?*api.Diagnostic) api.Error!Layout {
    const library = engine.library;
    library.clearError();
    if (detail) |diagnostic| diagnostic.deinit();
    if (requests.len != metrics.len) return error.InvalidArgument;
    @memset(metrics, .{ .width = 0, .height = 0, .baseline = 0 });
    var result = try layoutBatch(engine, requests);
    defer result.deinit();
    if (result.failure) |failure| {
        if (detail) |diagnostic| diagnostic.* = result.takeDiagnostic();
        return failure;
    }
    const layout = result.takeLayout() orelse return error.InvalidResult;
    @memcpy(metrics, layout.handle.?.measurements);
    return layout;
}

pub fn layoutBatch(engine: *api.Engine, requests: []const api.LayoutRequest) api.Error!BatchResult {
    const library = engine.library;
    library.clearError();
    const context = engine.handle orelse return error.InvalidState;
    if (engine.poisoned.load(.acquire)) return error.InvalidState;
    defer @import("Engine.zig").evict(library);

    if (try unsupported(library, requests)) |message| {
        try library.setError(message);
        return error.Unsupported;
    }
    var template_count: usize = 0;
    var module_count: usize = 0;
    for (requests) |request| {
        template_count += request.templates.len;
        module_count += request.modules.len;
    }
    const templates = try a.alloc(c.TypstTemplate, template_count);
    defer a.free(templates);
    var next_template: usize = 0;
    const modules = try a.alloc(?*const c.TypstModule, module_count);
    defer a.free(modules);
    var next_module: usize = 0;

    // One allocation holds the three contiguous arrays borrowed by the ABI.
    var descriptors = try std.MultiArrayList(struct {
        options: c.TypstLayoutOptions,
        native: c.TypstLayoutRequest,
        results: c.TypstLayoutResult,
    }).initCapacity(a, requests.len);
    defer descriptors.deinit(a);
    try descriptors.resize(a, requests.len);
    const fields = descriptors.slice();
    const options = fields.items(.options);
    const native = fields.items(.native);
    const results = fields.items(.results);
    for (requests, native, options) |request, *input, *config| {
        const region = request.region orelse api.Region{};
        config.* = std.mem.zeroes(c.TypstLayoutOptions);
        config.struct_size = @sizeOf(c.TypstLayoutOptions);
        config.flags = (if (region.expand_x) @as(u32, c.TYPST_EXPAND_X) else 0) |
            (if (region.expand_y) @as(u32, c.TYPST_EXPAND_Y) else 0) |
            (if (std.math.isFinite(region.width)) @as(u32, c.TYPST_BOUND_X) else 0) |
            (if (std.math.isFinite(region.height)) @as(u32, c.TYPST_BOUND_Y) else 0);
        config.width_pt = if (region.width == std.math.inf(f64)) 0 else region.width;
        config.height_pt = if (region.height == std.math.inf(f64)) 0 else region.height;
        config.syntax = switch (request.syntax) {
            .markup => c.TYPST_SYNTAX_MARKUP,
            .code => c.TYPST_SYNTAX_CODE,
            .math => c.TYPST_SYNTAX_MATH,
        };
        config.setup_code = binding.str(request.preamble);
        config.setup_source_name = binding.str("preamble");
        config.bindings = request.bindings.ptr;
        config.binding_count = request.bindings.len;
        const own = templates[next_template..][0..request.templates.len];
        next_template += own.len;
        for (own, request.templates) |*record, template| record.* = .{
            .code = binding.str(template.code),
            .source_name = binding.str(template.name),
            .setup_code = binding.str(template.setup),
            .setup_source_name = binding.str(template.setup_name),
            .bindings = template.bindings.ptr,
            .binding_count = template.bindings.len,
        };
        config.templates = own.ptr;
        config.template_count = own.len;
        config.shows = request.shows.ptr;
        config.show_count = request.shows.len;
        const own_modules = modules[next_module..][0..request.modules.len];
        next_module += own_modules.len;
        for (own_modules, request.modules) |*handle, module| handle.* = try module.native(library);
        config.module_handles = own_modules.ptr;
        config.module_handle_count = own_modules.len;
        config.show_values = request.show_values.ptr;
        config.show_value_count = request.show_values.len;
        input.* = .{ .source = binding.str(request.source), .source_name = binding.str("source"), .options = config };
    }
    @memset(results, std.mem.zeroes(c.TypstLayoutResult));
    defer for (results) |result| {
        library.functions.layout_release(result.layout);
        library.functions.diagnostics_release(result.diagnostics);
    };
    var global_report: ?*c.TypstDiagnostics = null;
    defer library.functions.diagnostics_release(global_report);
    const status = library.functions.context_layout_many(context, native.ptr, native.len, results.ptr, &global_report);
    if (status == c.TYPST_PANIC) engine.poisoned.store(true, .release);
    try library.check(status, global_report);

    var failure_index: ?usize = null;
    for (results, 0..) |result, index| {
        if (result.status == c.TYPST_PANIC) {
            engine.poisoned.store(true, .release);
            failure_index = index;
            break;
        }
    }
    if (failure_index == null) for (results, 0..) |result, index| {
        if (result.status != c.TYPST_OK) {
            failure_index = index;
            break;
        }
    };
    var outcome: BatchResult = .{};
    errdefer outcome.deinit();
    if (failure_index) |index| {
        const result = &results[index];
        const failure = if (binding.status(result.status)) |_| error.InvalidResult else |err| err;
        const message = message: {
            const text = try describe(library, result.diagnostics, requests[index]);
            if (text.len != 0) break :message text;
            a.free(text);
            break :message try a.dupe(u8, @errorName(failure));
        };
        errdefer a.free(message);
        try library.setError(message);
        outcome.failure = failure;
        outcome.diagnostic = .{
            .request_index = index,
            .library = library,
            .native = result.diagnostics,
            .message = .{ .library = library, .host = message },
        };
        result.diagnostics = null;
        if (failure == error.TypstPanic or index == 0) return outcome;
    }

    const completed = failure_index orelse results.len;
    const prefix = results[0..completed];
    const owner = try a.create(FrameBatch);
    errdefer a.destroy(owner);
    const frames = try a.alloc(*c.TypstLayout, completed);
    errdefer a.free(frames);
    const measured = try a.alloc(api.Metrics, completed);
    errdefer a.free(measured);
    var warnings: std.Io.Writer.Allocating = .init(a);
    errdefer warnings.deinit();
    for (prefix, measured, requests[0..completed], 0..) |result, *measurement, request, index| {
        const frame_owner = result.layout orelse return error.InvalidResult;
        var native_metrics: c.TypstMetrics = undefined;
        try library.check(library.functions.layout_metrics(frame_owner, &native_metrics), null);
        measurement.* = .{ .width = native_metrics.width_pt, .height = native_metrics.height_pt, .baseline = native_metrics.baseline_pt };
        if (!std.math.isFinite(measurement.width) or !std.math.isFinite(measurement.height) or !std.math.isFinite(measurement.baseline)) return error.InvalidResult;
        const warning = try describe(library, result.diagnostics, request);
        defer a.free(warning);
        if (warning.len != 0) {
            if (warnings.written().len != 0) warnings.writer.writeByte('\n') catch return error.OutOfMemory;
            warnings.writer.print("request {d}: {s}", .{ index, warning }) catch return error.OutOfMemory;
        }
    }
    const warning_text = try warnings.toOwnedSlice();
    for (prefix, frames) |*result, *frame_owner| {
        frame_owner.* = result.layout.?;
        result.layout = null;
    }
    owner.* = .{ .frames = frames, .measurements = measured, .warning_text = warning_text };
    outcome.layout = .{ .library = library, .handle = owner };
    return outcome;
}
