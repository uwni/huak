//! Huak owners and diagnostics for the stable native typography API.
const std = @import("std");
const binding = @import("typst_binding");
const SharedLibrary = @import("shared_library");
const host_types = @import("types.zig");
const diagnostic = @import("diagnostic.zig");
pub const c = binding.c;
pub const Error = binding.Error;
pub const abi_version = binding.abi_version;
pub const FontSource = host_types.FontSource;
pub const Input = host_types.Input;
pub const EngineOptions = host_types.EngineOptions;
pub const Syntax = host_types.Syntax;
pub const Region = host_types.Region;
pub const LayoutRequest = host_types.LayoutRequest;
pub const Metrics = host_types.Metrics;
pub const Engine = @import("Engine.zig");
pub const Layout = @import("layout.zig").Layout;
pub const BatchResult = @import("layout.zig").BatchResult;
pub const FrameRef = @import("layout.zig").FrameRef;
const a = binding.allocator;

// Typst workers may retain native TLS until process exit. Keep a single
// loader reference per actual image, including when opened under other names.
var resident: std.AutoHashMapUnmanaged(usize, SharedLibrary) = .empty;
var resident_mutex: std.Io.Mutex = .init;

/// Independently owned, including across subsequent or concurrent jobs.
pub const Diagnostic = struct {
    request_index: ?usize = null,
    message: ?Buffer = null,
    library: ?*Library = null,
    native: ?*c.TypstDiagnostics = null,

    pub fn text(self: *const Diagnostic) []const u8 {
        return if (self.message) |*message| message.bytes() else "";
    }
    pub fn deinit(self: *Diagnostic) void {
        if (self.message) |*message| message.deinit();
        if (self.library) |library| library.functions.diagnostics_release(self.native);
        self.* = .{};
    }
};

pub const Library = struct {
    functions: binding.Functions,
    version: u32 = abi_version,
    image_path: ?[:0]const u8 = null,
    capabilities: ?u64 = null,
    resources_mutex: std.Io.Mutex = .init,
    default_context: ?*c.TypstContext = null,
    diagnostic_mutex: std.Io.Mutex = .init,
    has_diagnostics: std.atomic.Value(bool) = .init(false),
    diagnostics: std.AutoHashMapUnmanaged(std.Thread.Id, []u8) = .empty,

    pub fn linked() Library {
        var functions: binding.Functions = undefined;
        inline for (@typeInfo(binding.Functions).@"struct".field_names) |name| @field(functions, name) = &@field(c, "typst_" ++ name);
        return .{ .functions = functions };
    }

    pub fn open(path: []const u8) Error!Library {
        var dynamic = try SharedLibrary.open(path);
        errdefer dynamic.close();
        var info: c.TypstVersionInfo = undefined;
        const functions = try binding.bind(&dynamic, &info);
        const image_path = SharedLibrary.imagePath(functions.abi_version) orelse return error.InvalidResult;
        std.Io.Threaded.mutexLockUncancelable(&resident_mutex);
        const installed = resident.getOrPut(a, @intFromPtr(dynamic.handle)) catch |err| {
            std.Io.Threaded.mutexUnlock(&resident_mutex);
            return err;
        };
        if (!installed.found_existing) installed.value_ptr.* = dynamic;
        std.Io.Threaded.mutexUnlock(&resident_mutex);
        if (installed.found_existing) dynamic.close();
        return .{ .functions = functions, .version = (@as(u32, info.abi_major) << 16) | info.abi_minor, .image_path = image_path, .capabilities = info.capabilities };
    }

    pub fn supports(self: *Library, feature: u64) Error!bool {
        if (self.capabilities) |bits| return bits & feature == feature;
        // Statically linked hosts construct the function table at comptime.
        var info: c.TypstVersionInfo = undefined;
        try self.check(self.functions.version_info(&info), null);
        return info.capabilities & feature == feature;
    }
    pub fn deinit(self: *Library) void {
        self.functions.context_release(self.default_context);
        var messages = self.diagnostics.valueIterator();
        while (messages.next()) |message| a.free(message.*);
        self.diagnostics.deinit(a);
        self.* = undefined;
    }

    /// Borrow the call's diagnostic; its owner always releases it separately.
    pub fn check(self: *Library, result: c.TypstStatus, report: ?*const c.TypstDiagnostics) Error!void {
        return self.checkDiagnosed(result, report, &.{});
    }
    pub fn checkDiagnosed(self: *Library, result: c.TypstStatus, report: ?*const c.TypstDiagnostics, sources: []const diagnostic.Source) Error!void {
        binding.status(result) catch |err| {
            const text = try diagnostic.format(self, report, sources);
            if (text.len == 0) {
                a.free(text);
                try self.setError(@errorName(err));
            } else self.setErrorOwned(text);
            return err;
        };
    }
    pub fn setError(self: *Library, message: []const u8) Error!void {
        self.setErrorOwned(try a.dupe(u8, message));
    }
    pub fn setErrorOwned(self: *Library, message: []u8) void {
        std.Io.Threaded.mutexLockUncancelable(&self.diagnostic_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.diagnostic_mutex);
        const result = self.diagnostics.getOrPut(a, std.Thread.getCurrentId()) catch {
            a.free(message);
            return;
        };
        if (result.found_existing) a.free(result.value_ptr.*);
        result.value_ptr.* = message;
        self.has_diagnostics.store(true, .release);
    }
    pub fn lastError(self: *Library) Error!Buffer {
        if (!self.has_diagnostics.load(.acquire)) return Buffer.copy(self, "");
        std.Io.Threaded.mutexLockUncancelable(&self.diagnostic_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.diagnostic_mutex);
        return Buffer.copy(self, self.diagnostics.get(std.Thread.getCurrentId()) orelse "");
    }
    pub fn clearError(self: *Library) void {
        if (!self.has_diagnostics.load(.acquire)) return;
        std.Io.Threaded.mutexLockUncancelable(&self.diagnostic_mutex);
        defer std.Io.Threaded.mutexUnlock(&self.diagnostic_mutex);
        if (self.diagnostics.fetchRemove(std.Thread.getCurrentId())) |entry| a.free(entry.value);
        if (self.diagnostics.count() == 0) self.has_diagnostics.store(false, .release);
    }
    pub fn createEngine(self: *Library) Error!Engine {
        return self.createEngineWithOptions(null);
    }
    pub fn createEngineWithOptions(self: *Library, options: ?*const EngineOptions) Error!Engine {
        self.clearError();
        return Engine.init(self, if (options) |value| value.* else .{});
    }
    pub fn sourceBlock(self: *Library, source: []const u8) Error!usize {
        self.clearError();
        return @import("syntax.zig").sourceBlock(self, source);
    }
    pub fn sameInstance(self: *const Library, other: *const Library) bool {
        return self == other or (self.functions.context_create == other.functions.context_create and
            self.functions.layout_release == other.functions.layout_release);
    }
};

/// Complete native documents and assembled scenes share the export interface.
pub const Document = struct {
    library: *Library,
    handle: ?union(enum) { document: *c.TypstDocument, scene: *c.TypstScene },
    warning_text: ?Buffer = null,

    pub fn fromOwned(library: *Library, document: *c.TypstDocument) Document {
        return .{ .library = library, .handle = .{ .document = document } };
    }
    pub fn fromSceneOwned(library: *Library, scene: *c.TypstScene) Document {
        return .{ .library = library, .handle = .{ .scene = scene } };
    }
    pub fn deinit(self: *Document) void {
        if (self.handle) |handle| switch (handle) {
            .document => |owner| self.library.functions.document_release(owner),
            .scene => |owner| self.library.functions.scene_release(owner),
        };
        self.handle = null;
        if (self.warning_text) |*warnings_buffer| warnings_buffer.deinit();
        self.warning_text = null;
    }
    pub fn pageCount(self: *const Document) Error!u32 {
        const handle = self.handle orelse return error.InvalidState;
        return switch (handle) {
            .document => |owner| std.math.cast(u32, self.library.functions.document_page_count(owner)) orelse error.InvalidResult,
            .scene => 1,
        };
    }
    pub fn exportSvg(self: *const Document, page: u32) Error!Buffer {
        self.library.clearError();
        const handle = self.handle orelse return error.InvalidState;
        defer @import("Engine.zig").evict(self.library);
        var output: ?*c.TypstBuffer = null;
        errdefer self.library.functions.buffer_release(output);
        var report: ?*c.TypstDiagnostics = null;
        defer self.library.functions.diagnostics_release(report);
        const result = switch (handle) {
            .document => |owner| self.library.functions.document_export_svg(owner, page, &output, &report),
            .scene => |owner| if (page == 0) self.library.functions.scene_export_svg(owner, &output, &report) else return error.InvalidPage,
        };
        try self.library.check(result, report);
        return Buffer.fromOwned(self.library, output orelse return error.InvalidResult);
    }
    pub fn exportPdf(self: *const Document) Error!Buffer {
        self.library.clearError();
        const handle = self.handle orelse return error.InvalidState;
        defer @import("Engine.zig").evict(self.library);
        var output: ?*c.TypstBuffer = null;
        errdefer self.library.functions.buffer_release(output);
        var report: ?*c.TypstDiagnostics = null;
        defer self.library.functions.diagnostics_release(report);
        const result = switch (handle) {
            .document => |owner| self.library.functions.document_export_pdf(owner, null, &output, &report),
            .scene => |owner| self.library.functions.scene_export_pdf(owner, null, &output, &report),
        };
        self.library.check(result, report) catch |err| return if (err == error.CompileFailed) error.ExportFailed else err;
        return Buffer.fromOwned(self.library, output orelse return error.InvalidResult);
    }
    pub fn warnings(self: *const Document) Error!Buffer {
        if (self.handle == null) return error.InvalidState;
        return Buffer.copy(self.library, if (self.warning_text) |*value| value.bytes() else "");
    }
};

pub const Buffer = struct {
    library: *Library,
    raw: ?*c.TypstBuffer = null,
    host: ?[]u8 = null,

    pub fn fromOwned(library: *Library, value: *c.TypstBuffer) Buffer {
        return .{ .library = library, .raw = value };
    }
    pub fn copy(library: *Library, source: []const u8) Error!Buffer {
        return .{ .library = library, .host = try a.dupe(u8, source) };
    }
    pub fn bytes(self: *const Buffer) []const u8 {
        if (self.host) |value| return value;
        return if (self.raw) |owner| binding.bytes(self.library.functions.buffer_data(owner)) else &.{};
    }
    pub fn deinit(self: *Buffer) void {
        self.library.functions.buffer_release(self.raw);
        self.raw = null;
        if (self.host) |value| a.free(value);
        self.host = null;
    }
};
