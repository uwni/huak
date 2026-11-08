//! Per-execution owners for existing geometry, pictures and native text frames.
//! The VM sees typed indices. Typst and geometry owners never cross the DSL API.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../drawing/geometry.zig");
const Path = @import("../drawing/path/Path.zig");
const Measure = @import("../drawing/path/Measure.zig");
const transform_geometry = @import("../drawing/transform/root.zig");
const mapping = transform_geometry.mapping;
const path_crossings = @import("../drawing/path/crossings.zig");
const path_construct = @import("../drawing/path/construct.zig");
const path_fillet = @import("../drawing/path/fillet.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const Scene = @import("../drawing/Scene.zig");
const pen_geometry = @import("../drawing/pen/root.zig");
const regions = @import("../drawing/region/root.zig");
const geometry_outline = @import("../drawing/outline.zig");
const region_geometry = @import("../drawing/region/coverage.zig");
const hobby = @import("../drawing/path/hobby.zig");
const constraints = @import("../drawing/solver.zig");
const outline = @import("../text/outline.zig");
const Machine = @import("Machine.zig");
const bc = @import("bytecode.zig");
const types = @import("types.zig");
const units = types.units;
const numeric_ops = @import("numeric.zig");
const special = @import("runtime/special.zig");
const builtin = @import("builtin.zig");
const AnimationState = @import("AnimationState.zig");
const renderer = @import("../render/root.zig");
const OutputBatch = @import("OutputBatch.zig");
const task_owners = @import("runtime/tasks.zig");
const typst_bindings = @import("runtime/typst_bindings.zig");
const Value = types.Value;
const Type = types.Type;
/// Optional builtin parameters may have compiler-inserted holes after named
/// arguments are reordered. An explicit unit remains a supplied value.
fn hasArgument(args: []const Value, index: usize) bool {
    return index < args.len and args[index] != .omitted;
}
const Expr = struct { owner: ?usize, expression: constraints.LinearExpr };
const Variable = struct { owner: usize, id: constraints.Var };
const Solved = struct { owner: usize, solution: constraints.Solution };
const Text = struct { layout: *typst.Layout, frame: usize, metrics: DisplayList.Metrics };
pub const SceneOwner = @import("runtime/objects.zig").Owner;
pub const Format = renderer.Format;
pub const Output = renderer.Output;
/// Host-owned services. Every worker borrows the same backends until it joins.
pub const Backends = struct {
    typst: *typst.Library,
    projection: ?*const @import("../drawing/space/Projection.zig").VTable = null,
};
pub const Options = struct {
    /// Configuration bytes are copied during Runtime.init. Library is borrowed
    /// at a stable address until Runtime and every exported result are freed.
    font_sources: []const typst.FontSource = &.{},
    use_bundled_fonts: bool = true,
    inputs: []const typst.Input = &.{},

    /// Build Typst sys.inputs from the entry script's prepared parameters.
    /// The caller supplies a scratch arena valid through Runtime.init.
    pub fn scriptInputs(arena: std.mem.Allocator, machine: *const Machine) ![]const typst.Input {
        var inputs: std.ArrayList(typst.Input) = .empty;
        for (machine.program.parameters) |parameter| {
            if (parameter.module != 0) continue;
            const value = machine.getGlobalAt(parameter.global) orelse return error.InvalidParameterState;
            const text: []const u8 = switch (value) {
                .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                .number => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                .quantity => try formatValue(arena, value),
                .boolean => |b| if (b) "true" else "false",
                .string => |s| s,
                else => return error.InvalidParameterState,
            };
            try inputs.append(arena, .{ .key = parameter.name, .value = text });
        }
        return inputs.items;
    }
};

const Runtime = @This();
const Model = @import("runtime/model.zig");
const Affine3 = @import("../drawing/transform/Affine3.zig");
const Transform = union(enum) {
    plane: struct { xy: g.Transform, z_scale: f64 },
    spatial: *const Affine3,

    pub fn matrix3(t: Transform) Affine3 {
        return switch (t) {
            .plane => |p| blk: {
                var matrix = Affine3.fromPlane(p.xy);
                matrix.rows[2][2] = p.z_scale;
                break :blk matrix;
            },
            .spatial => |p| p.*,
        };
    }
};

pub const TaskCheckpoint = task_owners.Checkpoint;
gpa: std.mem.Allocator,
/// Scene arrays and paints retain this allocator through output handoff.
scene_allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
backends: Backends,
options: Options,
outputs_taken: bool = false,
engine: ?typst.Engine = null,
/// Task children borrow a stable engine and immutable input owners until
/// their task group joins. Their metadata and arena remain independent.
shared_engine: ?*typst.Engine = null,
task_borrow: ?task_owners.Borrowed = null,
module_setups: std.ArrayList([]const u8) = .empty,
current_module: u32 = 0,
printed: std.ArrayList(u8) = .empty,
native_message: []const u8 = "",
path_values: std.ArrayList(Path) = .empty,
measures: std.ArrayList(Measure) = .empty,
colors: std.ArrayList(DisplayList.Color) = .empty,
pens: std.ArrayList(DisplayList.Pen) = .empty,
transforms: std.ArrayList(Transform) = .empty,
models: std.ArrayList(Model.Node) = .empty,
solvers: std.ArrayList(*constraints.Solver) = .empty,
variables: std.ArrayList(Variable) = .empty,
expressions: std.ArrayList(Expr) = .empty,
solutions: std.ArrayList(Solved) = .empty,
texts: std.ArrayList(Text) = .empty,
layouts: std.ArrayList(*typst.Layout) = .empty,
outline_cache: std.AutoHashMapUnmanaged(*const typst.Layout, outline.Batch) = .empty,
frames: std.ArrayList(typst.FrameRef) = .empty,
scene_values: std.ArrayList(*SceneOwner) = .empty,
/// Path and text nodes share storage pages, independent of their parent graph.
/// Each worker starts its own pages; output jobs retain only pages they use.
object_storage: ?u32 = null,

/// Both allocators must support concurrent use and remain valid until all
/// task results and outputs have been released. They may be the same allocator.
pub fn init(allocator: std.mem.Allocator, scene_allocator: std.mem.Allocator, library: *typst.Library, options: Options) !Runtime {
    return initWithBackends(allocator, scene_allocator, .{ .typst = library }, options);
}

pub fn initWithBackends(allocator: std.mem.Allocator, scene_allocator: std.mem.Allocator, backends: Backends, options: Options) !Runtime {
    var result: Runtime = .{ .gpa = allocator, .scene_allocator = scene_allocator, .arena = .init(allocator), .backends = backends, .options = options };
    errdefer result.deinit();
    const a = result.mem();
    const fonts = try a.alloc(typst.FontSource, options.font_sources.len);
    for (fonts, options.font_sources) |*out, in| {
        out.* = .{ .data = try a.dupe(u8, in.data) };
    }
    const inputs = try a.alloc(typst.Input, options.inputs.len);
    for (inputs, options.inputs) |*out, in| {
        out.* = .{ .key = try a.dupe(u8, in.key), .value = try a.dupe(u8, in.value) };
    }
    result.options.font_sources = fonts;
    result.options.inputs = inputs;
    return result;
}

pub fn deinit(self: *Runtime) void {
    const borrowed_measures = if (self.task_borrow) |borrowed| borrowed.measures else 0;
    for (self.measures.items[borrowed_measures..]) |*measure| measure.deinit();
    var cached_outlines = self.outline_cache.valueIterator();
    while (cached_outlines.next()) |batch| batch.deinit();
    const borrowed_layouts = if (self.task_borrow) |borrowed| borrowed.layouts else 0;
    for (self.layouts.items[borrowed_layouts..]) |layout| layout.deinit();
    if (self.engine) |*engine| engine.deinit();
    const borrowed_scenes = if (self.task_borrow) |borrowed| borrowed.scenes else 0;
    for (self.scene_values.items[borrowed_scenes..]) |target| {
        if (self.task_borrow) |borrowed| if (borrowed.adopted) |owners| if (owners.contains(&target.scene)) continue;
        target.scene.deinit();
        target.animation_state.deinit();
        self.gpa.destroy(target);
    }
    self.printed.deinit(self.gpa);
    self.arena.deinit();
    self.* = undefined;
}

const host_vtable: Machine.Host.VTable = .{ .call_builtin = call, .field = field, .binary = binary, .typst = typeset, .typst_batch = typesetBatch, .setup_typst = setupBlock, .module = selectModule, .error_message = diagnostic };
const single_host_vtable = blk: {
    var table = host_vtable;
    table.typst_batch = null;
    break :blk table;
};

pub fn host(self: *Runtime) Machine.Host {
    return .{ .ptr = self, .vtable = if (self.task_borrow == null) &host_vtable else &single_host_vtable };
}

/// Called by the coordinator before any children borrow this runtime.
/// The engine, options and input owners must outlive the joined group.
pub fn prepareTasks(self: *Runtime, needs_typst: bool) !void {
    if (self.outputs_taken or self.task_borrow != null) return error.InvalidState;
    if (needs_typst) _ = try self.engineRef();
}

/// Snapshot metadata on the coordinator; run the returned runtime on one
/// worker only. The root allocator must support concurrent allocation.
pub fn forkTask(self: *Runtime) !Runtime {
    return task_owners.fork(self);
}

/// Move a completed task's fresh picture back on the coordinator. The
/// child can be destroyed immediately after a successful handoff.
pub fn adoptTask(self: *Runtime, child: *Runtime, value: Value) !Value {
    return task_owners.adopt(self, child, value);
}

pub fn checkpointTasks(self: *const Runtime) TaskCheckpoint {
    return task_owners.checkpoint(self);
}

/// Revert unpublished task results before falling back to serial VM work.
pub fn rollbackTasks(self: *Runtime, marker: TaskCheckpoint) void {
    task_owners.rollback(self, marker);
}

pub fn printedText(self: *const Runtime) []const u8 {
    return self.printed.items;
}

pub fn nativeDiagnostic(self: *const Runtime) []const u8 {
    return self.native_message;
}

pub fn render(self: *Runtime, value: Value, format: Format) !Output {
    if (self.outputs_taken) return error.InvalidState;
    const target = try self.objectValue(value, false);
    var selected = try target.owner.viewWithBounds(self.gpa, target.index, renderer.FrameBounds{ .frames = self.frames.items });
    defer selected.deinit();
    const tracks = try selected.animation();
    if (tracks) |animation_| try animation_.validate();
    const scene: renderer.Scene = .{
        .picture = &selected.snapshot.picture,
        .size = selected.settings.size,
        .frames = self.frames.items,
        .object_ids = if (selected.tracks.items.len != 0) selected.snapshot.ids.items else null,
        .tracks = tracks,
    };
    var diagnostic_buffer: ?typst.Buffer = null;
    defer if (diagnostic_buffer) |*buffer| buffer.deinit();
    return scene.render(self.gpa, self.backends.typst, format, &diagnostic_buffer) catch |err| {
        if (diagnostic_buffer) |buffer| self.native_message = self.mem().dupe(u8, buffer.bytes()) catch "cannot copy native diagnostic";
        return err;
    };
}
/// Final handoff after script execution. Selected targets are moved, not
/// copied; their language handles must no longer be used. The batch survives
/// destruction of Runtime, Machine, Program and the native engine.
pub fn takeOutputs(self: *Runtime, values: []const Value) !OutputBatch {
    if (self.outputs_taken or self.task_borrow != null) return error.InvalidState;
    const sources = try self.gpa.alloc(OutputBatch.Source, values.len);
    defer self.gpa.free(sources);
    for (values, sources) |value, *source| {
        const target = try self.objectValue(value, false);
        source.* = target.owner.scene.object(target.index);
    }
    const batch = try OutputBatch.init(self.gpa, self.backends.typst, sources, self.frames.items);
    self.outputs_taken = true;
    return batch;
}
pub fn mem(self: *Runtime) std.mem.Allocator {
    return self.arena.allocator();
}
fn from(ctx: ?*anyopaque) *Runtime {
    return @ptrCast(@alignCast(ctx.?));
}
fn diagnostic(ctx: ?*anyopaque) []const u8 {
    return from(ctx).native_message;
}
fn captureNative(self: *Runtime) void {
    var buffer = self.backends.typst.lastError() catch return;
    defer buffer.deinit();
    self.native_message = self.mem().dupe(u8, buffer.bytes()) catch "cannot copy native diagnostic";
}
fn engineRef(self: *Runtime) !*typst.Engine {
    if (self.shared_engine) |engine| return engine;
    if (self.task_borrow != null) return error.TaskTypographyNotPrepared;
    if (self.engine == null) {
        const options: typst.EngineOptions = .{
            .font_sources = self.options.font_sources,
            .use_bundled_fonts = self.options.use_bundled_fonts,
            .inputs = self.options.inputs,
        };
        self.engine = self.backends.typst.createEngineWithOptions(&options) catch |err| {
            self.captureNative();
            return err;
        };
    }
    return &self.engine.?;
}
fn setupBlock(ctx: ?*anyopaque, source: []const u8) !void {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    const previous = self.moduleSetup();
    const combined = try std.fmt.allocPrint(self.mem(), "{s}\n{s}\n", .{ previous, source });
    try self.ensureModule();
    self.module_setups.items[self.current_module] = combined;
}
fn selectModule(ctx: ?*anyopaque, index: u32) !void {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    self.current_module = index;
}
fn ensureModule(self: *Runtime) !void {
    const length = @as(usize, self.current_module) + 1;
    if (length <= self.module_setups.items.len) return;
    const old_length = self.module_setups.items.len;
    try self.module_setups.resize(self.mem(), length);
    @memset(self.module_setups.items[old_length..], "");
}
fn moduleSetup(self: *const Runtime) []const u8 {
    return if (self.current_module < self.module_setups.items.len) self.module_setups.items[self.current_module] else "";
}
fn typeset(ctx: ?*anyopaque, allocator: std.mem.Allocator, request: Machine.TypstRequest) !Value {
    var values: [1]Value = undefined;
    var detail: Machine.TypstBatchDiagnostic = .{};
    try typesetBatch(ctx, allocator, &.{request}, &values, &detail);
    return values[0];
}
fn typesetBatch(ctx: ?*anyopaque, _: std.mem.Allocator, sources: []const Machine.TypstRequest, values: []Value, detail: *Machine.TypstBatchDiagnostic) !void {
    detail.* = .{};
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    if (sources.len != values.len) return error.InvalidArgument;
    self.native_message = "";
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    // This immutable string is the settings snapshot for this batch. The
    // VM never groups requests across a setup or module boundary.
    const setup = self.moduleSetup();
    const requests = try scratch.alloc(typst.LayoutRequest, sources.len);
    for (sources, requests) |input, *request| {
        const bindings = try typst_bindings.encode(scratch, input.bindings, self.colors.items);
        if (setup.len != 0) {
            // Independently parsed trees keep setup and body locations
            // distinct while applying setup's definitions and style rules.
            request.* = .{ .source = wrappedContent(input.source), .syntax = .markup, .preamble = setup, .bindings = bindings };
            continue;
        }
        // The compiler stored the content-block delimiters with this
        // constant, so code evaluation borrows the program's bytes.
        request.* = .{ .source = input.source, .syntax = .code, .bindings = bindings };
    }
    const metrics = try scratch.alloc(typst.Metrics, sources.len);
    var native_diagnostic: typst.Diagnostic = .{};
    defer native_diagnostic.deinit();
    const result = try self.retainTextBatch(requests, metrics, values, &native_diagnostic);
    detail.completed = result.completed;
    if (result.failure) |err| {
        if (native_diagnostic.text().len != 0) self.native_message = self.mem().dupe(u8, native_diagnostic.text()) catch return error.OutOfMemory;
        detail.request_index = native_diagnostic.request_index orelse 0;
        detail.message = self.native_message;
        return err;
    }
}
/// Compiler constants for `typ[...]` retain the content-block delimiters.
/// Setup layouts evaluate the inner markup directly; no second string copy
/// is needed for either form.
fn wrappedContent(source: []const u8) []const u8 {
    if (source.len >= 2 and source[0] == '[' and source[source.len - 1] == ']') return source[1 .. source.len - 1];
    return source;
}

fn retainTextBatch(self: *Runtime, requests: []const typst.LayoutRequest, metrics: []typst.Metrics, values: []Value, diagnostic_detail: *typst.Diagnostic) !struct { completed: usize, failure: ?typst.Error } {
    const a = self.mem();
    // Reserve all persistent metadata before acquiring a native owner; no
    // allocation or partial registration follows a successful layout call.
    const owner = try a.create(typst.Layout);
    try self.layouts.ensureUnusedCapacity(a, 1);
    try self.texts.ensureUnusedCapacity(a, requests.len);
    try self.frames.ensureUnusedCapacity(a, requests.len);
    const engine = try self.engineRef();
    var result = try engine.layoutBatch(requests);
    defer result.deinit();
    diagnostic_detail.* = result.takeDiagnostic();
    var completed: usize = 0;
    if (result.takeLayout()) |layout| {
        owner.* = layout;
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
fn store(self: *Runtime, comptime T: type, list: *std.ArrayList(T), value: T, kind: Type) !Value {
    const index = list.items.len;
    try list.append(self.mem(), value);
    return handle(kind, index);
}
pub fn path(self: *Runtime, value: Value) !Path {
    return self.path_values.items[try checkedIndex(value, .path, self.path_values.items.len)];
}
fn color(self: *Runtime, value: Value) !DisplayList.Color {
    return self.colors.items[try checkedIndex(value, .color, self.colors.items.len)];
}
fn penValue(self: *Runtime, value: Value) !DisplayList.Pen {
    return self.pens.items[try checkedIndex(value, .pen, self.pens.items.len)];
}
fn transformValue(self: *Runtime, value: Value) !g.Transform {
    return switch (try self.affineValue(value)) {
        .plane => |t| t.xy,
        .spatial => error.ExpectedPlanarTransform,
    };
}
pub fn affineValue(self: *Runtime, value: Value) !Transform {
    return self.transforms.items[try checkedIndex(value, .transform, self.transforms.items.len)];
}
pub fn model(self: *Runtime, value: Value) !Model.Node {
    return self.models.items[try checkedIndex(value, .shape, self.models.items.len)];
}
fn modelResult(self: *Runtime, kind: Model.Kind, args: []const Value) !Value {
    for (args) |value| switch (value) {
        .int, .number, .quantity, .vec2, .vec3 => {},
        .handle => |ref| switch (ref.kind) {
            .path, .shape, .transform => {},
            else => return error.InvalidModelArgument,
        },
        else => return error.InvalidModelArgument,
    };
    return self.store(Model.Node, &self.models, .{ .kind = kind, .arguments = try self.mem().dupe(Value, args) }, .shape);
}
fn textValue(self: *Runtime, value: Value) !Text {
    return self.texts.items[try checkedIndex(value, .text, self.texts.items.len)];
}
fn mutableSolver(self: *Runtime, index: usize) !*constraints.Solver {
    if (self.task_borrow) |borrowed| if (index < borrowed.solvers) return error.TaskCannotMutateBorrowedSolver;
    return self.solvers.items[index];
}
const Instance = struct { owner: *SceneOwner, index: Scene.Index };
/// Accumulated display clip. The scene stores one root path, so each call
/// intersects the current path with the new region before replacing it.
fn intersectClip(self: *Runtime, instance: Instance, region: *const Path) !void {
    var current = (try instance.owner.scene.currentClip(instance.index)) orelse {
        try instance.owner.scene.setClip(instance.index, region);
        return;
    };
    defer current.deinit();
    // An already empty clip stays empty, but the new region is still checked.
    if (current.segments.items.len == 0) {
        try Scene.validateClip(region);
        return;
    }
    var combined = try regions.combine(self.scene_allocator, current, region.*, .intersect, .{ .fill_rule = .nonzero });
    defer combined.deinit();
    if (combined.segments.items.len == 0) {
        try instance.owner.scene.setEmptyClip(instance.index);
    } else {
        try instance.owner.scene.setClip(instance.index, &combined);
    }
}
fn objectValue(self: *Runtime, value: Value, mutable: bool) !Instance {
    if (value != .object) return error.TypeMismatch;
    // Object values are unforgeable in the language and live only for this
    // execution. Validate ownership before accessing scene storage.
    const owner: *SceneOwner = @ptrCast(@alignCast(@constCast(value.object.owner)));
    const index = owner.owner_index;
    if (index >= self.scene_values.items.len or self.scene_values.items[index] != owner) return error.InvalidObject;
    if (mutable) if (self.task_borrow) |borrowed| if (index < borrowed.scenes) return error.TaskCannotMutateBorrowedPicture;
    _ = try owner.scene.getNode(value.object.index);
    return .{ .owner = owner, .index = value.object.index };
}
fn objectHandle(object_: Scene.Object) Value {
    const owner: *SceneOwner = @fieldParentPtr("scene", object_.scene);
    return .{ .object = .{ .owner = owner, .index = object_.index, .kind = if (owner.scene.nodes.items[object_.index] == .picture) .picture else .object } };
}
fn place(self: *Runtime, destination: Value, value: Value, transform: ?g.Transform) !Value {
    const target = try self.objectValue(destination, true);
    const source = try self.objectValue(value, true);
    if (try source.owner.scene.parentObject(source.index)) |parent| _ = try self.objectValue(objectHandle(parent), true);
    // A new descendant must satisfy the tracks on all destination ancestors.
    if (source.owner.hasGeometricStroke(source.index)) try checkStrokeAncestors(target);
    try target.owner.scene.place(target.index, source.owner.scene.object(source.index), transform);
    return value;
}
fn checkStrokeAncestors(instance: Instance) !void {
    var ancestor: ?Scene.Object = instance.owner.scene.object(instance.index);
    while (ancestor) |node| : (ancestor = try node.scene.parentObject(node.index)) {
        const owner: *SceneOwner = @fieldParentPtr("scene", node.scene);
        var tracks = owner.animation_state.iterator();
        while (tracks.next()) |track| {
            if (track.target != @as(u64, node.index) + 1) continue;
            switch (track.property) {
                .path, .stroke_width, .stroke, .fill => return error.UnsupportedNibAnimation,
                else => {},
            }
        }
    }
}
fn hasAnimation(self: *Runtime, object: Instance) bool {
    for (self.scene_values.items) |owner| {
        var tracks = owner.animation_state.iterator();
        while (tracks.next()) |track| {
            const index = std.math.cast(Scene.Index, track.target - 1) orelse continue;
            if (owner.scene.contains(index, object.owner.scene.object(object.index)) or object.owner.scene.contains(object.index, owner.scene.object(index))) {
                return true;
            }
        }
    }
    return false;
}
fn requireStatic(self: *Runtime, object: Instance) !void {
    if (self.hasAnimation(object)) {
        self.native_message = "operation requires a static object (including its ancestors and descendants)";
        return error.AnimatedPicture;
    }
}
fn objectSnapshot(self: *Runtime, value: Value, static: bool) !Scene.Snapshot {
    const object = try self.objectValue(value, false);
    if (static) try self.requireStatic(object);
    return object.owner.scene.snapshotWithBounds(self.gpa, object.index, null, renderer.FrameBounds{ .frames = self.frames.items });
}
pub fn pathResult(self: *Runtime, value: Path) !Value {
    return self.store(Path, &self.path_values, value, .path);
}
fn outlinedLabel(self: *Runtime, reference: usize) !*const outline.Label {
    if (reference >= self.texts.items.len) return error.InvalidFrameReference;
    const text = self.texts.items[reference];
    const batch = self.outline_cache.getPtr(text.layout) orelse cache: {
        var extracted = outline.extract(self.gpa, text.layout) catch |err| {
            self.captureNative();
            return err;
        };
        errdefer extracted.deinit();
        try self.outline_cache.put(self.mem(), text.layout, extracted);
        break :cache self.outline_cache.getPtr(text.layout).?;
    };
    if (text.frame >= batch.labels.len) return error.InvalidFrameReference;
    return &batch.labels[text.frame];
}
pub fn resolveOutline(self: *Runtime, allocator: std.mem.Allocator, reference: u32) !DisplayList {
    const label = try self.outlinedLabel(reference);
    var result = DisplayList.init(allocator);
    errdefer result.deinit();
    // Cached editable glyphs are baseline-relative and y-up. DisplayList's
    // label transform expects original frame-local y-down coordinates.
    try label.addToPicture(&result, .{ .d = -1, .f = label.metrics.baseline });
    return result;
}
/// Preserve drawing data. Numeric region conversion belongs to the
/// polygon adapter and must not be an implicit part of this snapshot.
fn vectorPicture(self: *Runtime, allocator: std.mem.Allocator, object: Value, operation: builtin.Id) !DisplayList {
    switch (object.valueType()) {
        .path => return geometry_outline.extract(allocator, .{ .path = try self.path(object) }, self),
        .text => {
            const reference = try checkedIndex(object, .text, self.texts.items.len);
            var result = DisplayList.init(allocator);
            errdefer result.deinit();
            // The cached parts are already an ordinary path picture; build
            // it once instead of copying it through an intermediate
            // picture and a second outline extraction.
            try (try self.outlinedLabel(reference)).addToPicture(&result, .{});
            try geometry_outline.ensureWithinBudget(&result);
            return result;
        },
        .object, .picture => {
            var selected = try self.objectSnapshot(object, true);
            defer selected.deinit();
            return geometry_outline.extract(allocator, .{ .picture = &selected.picture }, self);
        },
        else => {
            self.native_message = if (operation == .region) "region requires a path, text, or object" else "outlines requires a path, text, or object";
            return error.TypeMismatch;
        },
    }
}
fn extractOutlines(self: *Runtime, object: Value) !Value {
    return self.objectResult(try self.vectorPicture(self.scene_allocator, object, .outlines));
}
fn rawPaths(self: *Runtime, allocator: std.mem.Allocator, object: Value) !Value {
    var selected = try self.objectSnapshot(object, true);
    defer selected.deinit();
    var extracted: ?DisplayList = null;
    defer if (extracted) |*value| value.deinit();
    const source = source: {
        for (selected.picture.commands.items) |command| if (command == .label) {
            extracted = try geometry_outline.extract(self.gpa, .{ .picture = &selected.picture }, self);
            break :source &extracted.?;
        };
        break :source &selected.picture;
    };
    const raw = try geometry_outline.rawPaths(self.mem(), source);
    const result = try allocator.alloc(Value, raw.len);
    errdefer allocator.free(result);
    for (result, raw) |*value, path_| value.* = try self.pathResult(path_);
    return types.listView(result);
}
fn transformResult(self: *Runtime, value: g.Transform, z_scale: f64) !Value {
    if (!value.isFinite() or !std.math.isFinite(z_scale)) return error.NonFinite;
    return self.store(Transform, &self.transforms, .{ .plane = .{ .xy = value, .z_scale = z_scale } }, .transform);
}
fn spatialTransform(self: *Runtime, value: Affine3) !Value {
    for (value.rows) |row| for (row) |v| {
        if (!std.math.isFinite(v)) return error.NonFinite;
    };
    const matrix = try self.mem().create(Affine3);
    matrix.* = value;
    return self.store(Transform, &self.transforms, .{ .spatial = matrix }, .transform);
}
fn field(ctx: ?*anyopaque, allocator: std.mem.Allocator, object: Value, name: []const u8) !Value {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    if (object.valueType() == .shape) {
        const node = try self.model(object);
        if (std.mem.eql(u8, name, "kind")) return .{ .string = @tagName(node.kind) };
        if (std.mem.eql(u8, name, "arguments")) return types.listView(node.arguments);
    } else if (object.valueType() == .path and std.mem.eql(u8, name, "linear_axis")) {
        const axis = (try self.path(object)).linearAxis() orelse return .{ .boolean = false };
        return types.listView(try allocator.dupe(Value, &.{ .{ .vec2 = types.Vec2.fromPoint(axis[0]) }, .{ .vec2 = types.Vec2.fromPoint(axis[1]) } }));
    } else if (object.valueType() == .color) {
        const rgba = try self.color(object);
        inline for (.{ "r", "g", "b", "a" }) |channel|
            if (std.mem.eql(u8, name, channel)) return .{ .number = @field(rgba, channel) };
    } else if (object.valueType() == .text) {
        const metrics = (try self.textValue(object)).metrics;
        if (std.mem.eql(u8, name, "width")) return lengthResult(metrics.width);
        if (std.mem.eql(u8, name, "height")) return lengthResult(metrics.height);
        if (std.mem.eql(u8, name, "baseline")) return lengthResult(metrics.baseline);
    } else if (object.valueType() == .solution) {
        const solved = self.solutions.items[try checkedIndex(object, .solution, self.solutions.items.len)].solution;
        if (std.mem.eql(u8, name, "status")) return .{ .string = @tagName(solved.status) };
        if (std.mem.eql(u8, name, "rank")) return .{ .int = @intCast(solved.rank) };
    } else if (object == .object) {
        const instance = try self.objectValue(object, false);
        if (object.valueType() == .picture) {
            if (std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height")) {
                const settings = try instance.owner.scene.settings(instance.index);
                const size = settings.size orelse size: {
                    var selected = try self.objectSnapshot(object, false);
                    defer selected.deinit();
                    const viewport = try renderer.viewport(&selected.picture, null, self.frames.items);
                    break :size viewport.max.sub(viewport.min);
                };
                return lengthResult(if (std.mem.eql(u8, name, "width")) size.x else size.y);
            }
        }
        if (std.mem.eql(u8, name, "paths")) return self.rawPaths(allocator, object);
        if (std.mem.eql(u8, name, "visible")) return .{ .boolean = try instance.owner.scene.isVisible(instance.index) };
        if (std.mem.eql(u8, name, "parent")) return if (try instance.owner.scene.parentObject(instance.index)) |parent| objectHandle(parent) else .{ .boolean = false };
        if (std.mem.eql(u8, name, "children")) {
            var iterator = try instance.owner.scene.children(instance.index);
            var values: std.ArrayList(Value) = .empty;
            errdefer values.deinit(allocator);
            while (iterator.next()) |child| try values.append(allocator, objectHandle(child));
            return types.listView(try values.toOwnedSlice(allocator));
        }
        const command = try instance.owner.scene.getNode(instance.index);
        if (std.mem.eql(u8, name, "transform")) return self.transformResult(switch (command.*) {
            .path => |draw| draw.transform,
            .label => |label| label.transform,
            .picture => |group| group.transform,
        }, 1);
        if (std.mem.eql(u8, name, "fill") or std.mem.eql(u8, name, "pen")) {
            if (command.* != .path) return error.ExpectedPathObject;
            if (std.mem.eql(u8, name, "fill")) return if (command.path.style.fill) |value| self.store(DisplayList.Color, &self.colors, value, .color) else .{ .boolean = false };
            var value = command.path.style.pen orelse return .{ .boolean = false };
            try value.cloneData(self.mem());
            errdefer value.freeData(self.mem());
            return self.store(DisplayList.Pen, &self.pens, value, .pen);
        }
        if (std.mem.eql(u8, name, "animated")) {
            return .{ .boolean = self.hasAnimation(instance) };
        }
        if (std.mem.eql(u8, name, "kind")) return .{ .string = switch ((try instance.owner.scene.getNode(instance.index)).*) {
            .path => "path",
            .label => "text",
            .picture => "picture",
        } };
    } else if (object.valueType() == .measure) {
        const measure = self.measures.items[try checkedIndex(object, .measure, self.measures.items.len)];
        if (std.mem.eql(u8, name, "length")) return lengthResult(measure.length);
        if (std.mem.eql(u8, name, "contours")) return .{ .int = @intCast(measure.contours.len) };
        if (std.mem.eql(u8, name, "curves")) {
            const curves = try allocator.alloc(Value, measure.curves.len);
            for (curves, measure.curves) |*value, curve| {
                const points = try allocator.alloc(Value, 4);
                for (points, [_]g.Point{ curve.p0, curve.p1, curve.p2, curve.p3 }) |*point_, point_value| point_.* = .{ .vec2 = types.Vec2.fromPoint(point_value) };
                value.* = types.listView(points);
            }
            return types.listView(curves);
        }
    }
    return error.UnknownField;
}
fn call(ctx: ?*anyopaque, a: std.mem.Allocator, id: builtin.Id, args: []const Value, machine: ?*Machine) anyerror!Value {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    self.native_message = "";
    if (id == .mapped) return self.mapObject(machine orelse return error.CallbackUnavailable, args);
    return self.invoke(a, id, args);
}
pub fn animationPath(self: *Runtime, value: Value) ![]const Path.Segment {
    return (try self.path(value)).segments.items;
}
fn mapObject(self: *Runtime, machine: *Machine, args: []const Value) !Value {
    // No operand slices or mutable picture commands may be borrowed across
    // script callbacks: they can grow the VM stack and runtime registries.
    const object = args[0];
    const function = args[1];
    const context: ?Value = if (hasArgument(args, 2)) args[2] else null;
    const options: mapping.Options = .{ .tolerance = if (hasArgument(args, 3)) try lengthPoints(args[3]) else 1e-3 };
    try options.validate();
    const affine = if (function.valueType() == .transform) try self.transformValue(function) else null;
    if (affine == null and function != .function) return error.TypeMismatch;
    const operator: @import("runtime/Mapping.zig") = .{ .machine = machine, .function = function, .context = context };
    if (object.valueType() == .path) {
        const source = try self.path(object);
        return self.pathResult(if (affine) |t| try source.transformed(self.mem(), t) else try mapping.mapped(self.mem(), source, operator, options));
    }
    if (affine) |t| return self.transformedObject(object, t);
    var selected = try self.objectSnapshot(object, true);
    defer selected.deinit();
    var snapshot = try geometry_outline.extract(self.gpa, .{ .picture = &selected.picture }, null);
    defer snapshot.deinit();
    return self.objectResult(try mapping.picture(self.scene_allocator, &snapshot, operator, options));
}
fn transformedObject(self: *Runtime, object: Value, transform: g.Transform) !Value {
    var selected = try self.objectSnapshot(object, true);
    defer selected.deinit();
    const copied = copy: {
        var result = DisplayList.init(self.scene_allocator);
        errdefer result.deinit();
        try result.append(&selected.picture, transform);
        break :copy result;
    };
    return self.objectResult(copied);
}
/// Both helpers consume their input, including allocation-failure paths.
fn objectResult(self: *Runtime, value: DisplayList) !Value {
    var result = value;
    errdefer result.deinit();
    return self.sceneResult(try Scene.fromDisplayList(&result), 0);
}
fn sceneResult(self: *Runtime, value: Scene, index: Scene.Index) !Value {
    const target = try self.storeScene(value);
    return objectHandle(target.scene.object(index));
}
fn storeScene(self: *Runtime, value: Scene) !*SceneOwner {
    var scene = value;
    errdefer scene.deinit();
    const target = try self.gpa.create(SceneOwner);
    errdefer self.gpa.destroy(target);
    target.* = .{ .scene = scene, .owner_index = try self.nextOwnerIndex(), .animation_state = .init(self.gpa) };
    try self.scene_values.append(self.mem(), target);
    return target;
}
fn objectStorage(self: *Runtime, curve: ?*const Path) !*SceneOwner {
    const page_budget = 64 * 1024;
    if (self.object_storage) |index| {
        const owner = self.scene_values.items[index];
        // Bound array growth before insertion consumes the page budget.
        // An oversized object occupies a fresh page of its own. Styles and
        // tracks added later count toward the next insertion's budget.
        if (try owner.scene.reserveNode(curve, page_budget -| owner.animation_state.allocatedBytes())) return owner;
    }
    var fresh: Scene = .{ .storage = .init(self.scene_allocator) };
    // Apply the same bounded growth to the first object. A path larger than
    // the entire page may still be stored alone.
    _ = fresh.reserveNode(curve, page_budget) catch |err| {
        fresh.deinit();
        return err;
    };
    const owner = try self.storeScene(fresh);
    self.object_storage = owner.owner_index;
    return owner;
}
fn pathObject(self: *Runtime, curve: *const Path, style: *const DisplayList.Style, transform: g.Transform) !Value {
    const owner = try self.objectStorage(curve);
    return .{ .object = .{ .owner = owner, .index = try owner.scene.addPath(null, curve, style, transform) } };
}

fn labelObject(self: *Runtime, reference: u32, position: g.Point, transform: g.Transform) !Value {
    const owner = try self.objectStorage(null);
    return .{ .object = .{ .owner = owner, .index = try owner.scene.label(null, reference, self.texts.items[reference].metrics, position, transform) } };
}
fn nextOwnerIndex(self: *Runtime) !u32 {
    if (self.scene_values.items.len >= std.math.maxInt(u32)) return error.TooManyObjects;
    return @intCast(self.scene_values.items.len);
}
pub fn animationColor(self: *Runtime, value: Value) !DisplayList.Color {
    return self.color(value);
}
fn invoke(self: *Runtime, a: std.mem.Allocator, id: builtin.Id, args: []const Value) !Value {
    const own = self.mem();
    switch (id) {
        .project_scene => return @import("runtime/projection.zig").project(self, a, args),
        .model_shape => return self.modelResult(std.meta.stringToEnum(Model.Kind, try string(args[0])) orelse return error.InvalidModelShape, try sequence(args[1])),
        .matrix => return self.transformResult(.{ .a = try numeric(args[0]), .b = try numeric(args[1]), .c = try numeric(args[2]), .d = try numeric(args[3]), .e = try lengthPoints(args[4]), .f = try lengthPoints(args[5]) }, 1),
        .timeline => {
            const target = try self.objectValue(args[0], true);
            const settings = try target.owner.scene.settings(target.index);
            const duration = try numeric(args[1]);
            const repeat = if (hasArgument(args, 2)) try boolean(args[2]) else true;
            try (@import("../animation/root.zig").Animation{ .duration_seconds = duration, .repeat = repeat, .tracks = &.{} }).validate();
            settings.duration = duration;
            settings.repeat = repeat;
            return .unit;
        },
        .animate, .motion => {
            const instance = try self.objectValue(args[0], true);
            const target = instance.owner;
            if (id == .animate) {
                const property = try string(args[1]);
                if ((std.mem.eql(u8, property, "path") or std.mem.eql(u8, property, "stroke_width") or std.mem.eql(u8, property, "stroke") or std.mem.eql(u8, property, "fill")) and target.hasGeometricStroke(instance.index)) return error.UnsupportedNibAnimation;
                try target.animation_state.animate(instance.index, property, try sequence(args[2]), if (hasArgument(args, 3)) try string(args[3]) else "linear", self);
            } else {
                try target.animation_state.motion(instance.index, args[1], try sequence(args[2]), if (hasArgument(args, 3)) try string(args[3]) else "auto", self);
            }
            return .unit;
        },
        .object_transform, .object_remove, .object_before, .object_style, .object_visible, .object_clip, .object_reset_clip => {
            const instance = try self.objectValue(args[0], true);
            switch (id) {
                .object_visible => {
                    try instance.owner.scene.setVisible(instance.index, try boolean(args[1]));
                },
                .object_style => {
                    const command = try instance.owner.scene.getNode(instance.index);
                    if (command.* != .path) return error.ExpectedPathObject;
                    var style = command.path.style.*;
                    if (hasArgument(args, 1)) {
                        style.fill = if (args[1] == .boolean and !args[1].boolean) null else try self.color(args[1]);
                        style.gradient = style.gradientFor(.stroke);
                    }
                    if (hasArgument(args, 2)) {
                        style.pen = if (args[2] == .boolean and !args[2].boolean) null else try self.penValue(args[2]);
                        style.gradient = style.gradientFor(.fill);
                    }
                    if (style.pen) |stroke| if (stroke.needsGeometry()) try checkStrokeAncestors(instance);
                    try instance.owner.scene.setStyle(instance.index, &style);
                },
                .object_transform => try instance.owner.scene.applyTransform(instance.index, try self.transformValue(args[1])),
                .object_clip => {
                    const region = try self.path(args[1]);
                    try self.intersectClip(instance, &region);
                },
                .object_reset_clip => try instance.owner.scene.setClip(instance.index, null),
                .object_remove => {
                    try instance.owner.scene.remove(instance.index);
                },
                .object_before => {
                    const sibling = try self.objectValue(args[1], true);
                    try instance.owner.scene.before(instance.index, sibling.owner.scene.object(sibling.index));
                },
                else => unreachable,
            }
            return .unit;
        },
        .copy => {
            const source = try self.objectValue(args[0], false);
            try self.requireStatic(source);
            const target = try self.storeScene(try source.owner.scene.copy(self.scene_allocator, source.index));
            return objectHandle(target.scene.object(0));
        },
        .object_exclude => {
            const sweep = try self.path(args[2]);
            var painted: ?Path = null;
            defer if (painted) |*path_| path_.deinit();
            if (hasArgument(args, 3)) {
                const brush = try self.penValue(args[3]);
                painted = try renderer.strokeFootprint(self.gpa, self.gpa, sweep, &brush, null);
            }
            const parent = try self.objectValue(args[0], true);
            const values = try sequence(args[1]);
            const targets = try self.gpa.alloc(Scene.Object, values.len);
            defer self.gpa.free(targets);
            for (values, targets) |value, *object| {
                const target = try self.objectValue(value, true);
                object.* = target.owner.scene.object(target.index);
            }
            parent.owner.scene.exclude(parent.index, targets, painted orelse sweep) catch |err| {
                if (err == error.DifferentParents) self.native_message = "erase targets must be direct children of the current drawing";
                return err;
            };
            return .unit;
        },
        .snapshot => return self.transformedObject(args[0], .{}),
        .print => {
            if (self.task_borrow != null) return error.TaskSideEffect;
            const message = try formatValue(a, args[0]);
            try self.printed.appendSlice(self.gpa, message);
            try self.printed.append(self.gpa, '\n');
            return .unit;
        },
        .panic, .dict_contains, .dict_remove, .dict_keys, .seed, .random, .randint, .randn => return error.InvalidBuiltin,
        .len => return .{ .int = @intCast(switch (args[0]) {
            .handle => if (args[0].valueType() == .path) (try self.path(args[0])).segmentCount() else return error.TypeMismatch,
            else => return error.TypeMismatch,
        }) },
        .to_int => return .{ .int = switch (args[0]) {
            .int => |v| v,
            .number => |v| blk: {
                if (!std.math.isFinite(v) or v < -0x1p63 or v >= 0x1p63) return error.IntegerOverflow;
                break :blk @intFromFloat(v);
            },
            .string => |v| try std.fmt.parseInt(i64, v, 10),
            else => return error.TypeMismatch,
        } },
        .to_number => return number(switch (args[0]) {
            .string => |v| try std.fmt.parseFloat(f64, v),
            else => try numeric(args[0]),
        }),
        .to_string => return .{ .string = try formatValue(a, args[0]) },
        .sin, .cos, .tan => {
            const x = try angular(args[0]);
            return number(switch (id) {
                .sin => @sin(x),
                .cos => @cos(x),
                .tan => @tan(x),
                else => unreachable,
            });
        },
        .gamma, .lgamma => {
            const x = try numeric(args[0]);
            if (x <= 0 and x == @trunc(x)) return error.DomainError;
            return number(if (id == .gamma) std.math.gamma(f64, x) else std.math.lgamma(f64, x));
        },
        .beta => return number(try special.beta(try numeric(args[0]), try numeric(args[1]))),
        .erf => return number(special.erf(try numeric(args[0]))),
        .erfc => return number(special.erfc(try numeric(args[0]))),
        .sqrt, .abs => {
            var quantity = try types.asQuantity(args[0]);
            if (id == .sqrt) quantity = try units.squareRoot(quantity) else quantity.value = @abs(quantity.value);
            return types.fromQuantity(try quantity.checked());
        },
        .log, .log10 => {
            const x = try numeric(args[0]);
            if (x <= 0) return error.DomainError;
            return number(if (id == .log) @log(x) else @log10(x));
        },
        .floor, .ceil => {
            const x = try numeric(args[0]);
            return number(if (id == .floor) @floor(x) else @ceil(x));
        },
        .min, .max, .pow, .atan2 => {
            const x = try types.asQuantity(args[0]);
            const y = try types.asQuantity(args[1]);
            if (id == .pow) return types.fromQuantity(try units.arithmetic(.power, x, y));
            const order = try units.compare(x, y);
            if (id == .atan2) return .{ .quantity = .{ .value = std.math.atan2(x.value, y.value), .dimension = .rotation } };
            return if ((id == .min and order != .gt) or (id == .max and order != .lt)) args[0] else args[1];
        },
        .vec2 => return numeric_ops.makeVec2(args[0], args[1]),
        .vec3 => return numeric_ops.makeVector(3, args[0..3].*),
        .dot, .norm, .unit => switch (args[0]) {
            inline .vec2, .vec3 => |v, tag| {
                if (!v.isFinite()) return error.NonFinite;
                if (id == .dot) {
                    if (args[1] != tag) return error.TypeMismatch;
                    const w = @field(args[1], @tagName(tag));
                    const dot = v.x * w.x + v.y * w.y + (if (tag == .vec3) v.z * w.z else 0);
                    return types.fromQuantity(try (units.Quantity{ .value = dot, .dimension = try v.dimension.combine(w.dimension, false) }).checked());
                }
                if (id == .norm) {
                    const xy = std.math.hypot(v.x, v.y);
                    return types.fromQuantity(try (units.Quantity{ .value = if (tag == .vec3) std.math.hypot(xy, v.z) else xy, .dimension = v.dimension }).checked());
                }
                if (tag == .vec2) {
                    const n = try (g.Point{ .x = v.x, .y = v.y }).normalized();
                    return .{ .vec2 = .{ .x = n.x, .y = n.y } };
                } else {
                    const max = @max(@abs(v.x), @abs(v.y), @abs(v.z));
                    if (max == 0) return error.ZeroVector;
                    const n: types.Vec3 = .{ .x = v.x / max, .y = v.y / max, .z = v.z / max };
                    return .{ .vec3 = n.scale(1 / std.math.hypot(std.math.hypot(n.x, n.y), n.z)) };
                }
            },
            else => return error.TypeMismatch,
        },
        .lerp => {
            const difference = try numeric_ops.valueArithmetic(.subtract, args[1], args[0]);
            return numeric_ops.valueArithmetic(.add, args[0], try numeric_ops.valueArithmetic(.multiply, difference, args[2]));
        },
        .rgb => {
            const value = DisplayList.Color{ .r = try numeric(args[0]), .g = try numeric(args[1]), .b = try numeric(args[2]), .a = if (hasArgument(args, 3)) try numeric(args[3]) else 1 };
            if (!value.valid()) return error.InvalidColor;
            return self.store(DisplayList.Color, &self.colors, value, .color);
        },
        .pen => {
            var value = DisplayList.Pen{ .color = try self.color(args[0]), .width = if (hasArgument(args, 1)) try lengthPoints(args[1]) else 1 };
            if (hasArgument(args, 2)) value.cap = std.meta.stringToEnum(DisplayList.Cap, try string(args[2])) orelse return error.InvalidPen;
            if (hasArgument(args, 3)) value.join = std.meta.stringToEnum(DisplayList.Join, try string(args[3])) orelse return error.InvalidPen;
            if (hasArgument(args, 4)) value.miter_limit = try numeric(args[4]);
            if (hasArgument(args, 5)) {
                const input = try sequence(args[5]);
                const dash = try own.alloc(f64, input.len);
                for (input, dash) |item, *out| out.* = try lengthPoints(item);
                value.dash = dash;
            }
            if (hasArgument(args, 6)) value.dash_phase = try lengthPoints(args[6]);
            if (hasArgument(args, 7)) {
                // The source contributes only immutable nib geometry;
                // this constructor independently specifies all paint state.
                value.nib = try (try self.penValue(args[7])).fixedNib();
            }
            const legacy = hasArgument(args, 8);
            if (legacy or hasArgument(args, 9)) {
                if (legacy and (hasArgument(args, 1) or value.nib != null or hasArgument(args, 9)) or value.dash.len != 0) {
                    self.native_message = "profile supplies the full width of a solid circular pen; motion uses a solid base nib";
                    return error.InvalidPen;
                }
                if ((hasArgument(args, 2) and (!legacy or value.cap != .round)) or
                    (hasArgument(args, 3) and (!legacy or value.join != .round)) or hasArgument(args, 4))
                {
                    self.native_message = "the moving nib defines its own ends and corners";
                    return error.InvalidPen;
                }
                value.cap = .round;
                value.join = .round;
                const tolerance = if (hasArgument(args, 10)) try lengthPoints(args[10]) else 0.001;
                value.motion = readMotion(own, if (legacy) args[8] else args[9], legacy, tolerance) catch |err| {
                    self.native_message = switch (err) {
                        error.InvalidFrameCorner => "frame corner must be strict, rotate, or overlap",
                        error.ConflictingFrameCorners => "path frames in one motion must use the same corner policy",
                        else => "motion requires a bounded polynomial or ordered [fraction,value] keys, nonnegative scale controls, and a positive physical tolerance",
                    };
                    if (legacy and err == error.InvalidMotion) return error.InvalidProfile;
                    return err;
                };
            } else if (hasArgument(args, 10)) return error.InvalidMotion;
            try DisplayList.validateStyle(&.{ .pen = value });
            return self.store(DisplayList.Pen, &self.pens, value, .pen);
        },
        .pencircle, .pensquare => {
            const width = if (hasArgument(args, 0)) try lengthPoints(args[0]) else 1;
            if (!std.math.isFinite(width) or width < 0) return error.InvalidPen;
            const source = if (id == .pencircle) pen_geometry.Nib.circle() else pen_geometry.Nib.square();
            const transformed_nib = try source.transformed(own, .scaling(width, width));
            return self.store(DisplayList.Pen, &self.pens, .{ .nib = transformed_nib.nib, .color = if (hasArgument(args, 1)) try self.color(args[1]) else .black, .cap = .round, .join = .round }, .pen);
        },
        .makepen => {
            const retained = try pen_geometry.makePen(own, try self.path(args[0]));
            return self.store(DisplayList.Pen, &self.pens, .{ .nib = retained.nib, .color = if (hasArgument(args, 1)) try self.color(args[1]) else .black, .cap = .round, .join = .round }, .pen);
        },
        .makepath, .penoffset => {
            const nib = try (try self.penValue(args[0])).fixedNib();
            if (id == .makepath) return self.pathResult(try nib.makePath(own));
            return .{ .vec2 = types.Vec2.fromPoint(try nib.offset(try point(args[1]))) };
        },
        .envelope => {
            const brush = try self.penValue(args[1]);
            var config: pen_geometry.EnvelopeOptions = .{ .cap = brush.cap, .join = brush.join, .miter_limit = brush.miter_limit };
            if (hasArgument(args, 2)) config.tolerance = try lengthPoints(args[2]);
            const result = pen_geometry.envelope(own, try brush.fixedNib(), try self.path(args[0]), config) catch |err| {
                if (err == error.EllipticalPen) self.native_message = "envelope requires a polygonal pen; use pensquare or makepen";
                return err;
            };
            return self.pathResult(result);
        },
        .stroke_outline => {
            const tolerance = if (hasArgument(args, 2)) try lengthPoints(args[2]) else null;
            const brush = try self.penValue(args[1]);
            return self.pathResult(try pen_geometry.footprint(own, self.gpa, try self.path(args[0]), &brush, tolerance));
        },
        .translate => {
            if (args[0] == .vec3) {
                const p = try args[0].vec3.points();
                var t: Affine3 = .{};
                for (&t.rows, p) |*row, v| row[3] = v;
                return self.spatialTransform(t);
            }
            const p = try point(args[0]);
            return self.transformResult(.translation(p.x, p.y), 1);
        },
        .scale => {
            const x = try numeric(args[0]);
            const t = g.Transform.scaling(x, if (hasArgument(args, 1)) try numeric(args[1]) else x);
            if (!hasArgument(args, 2)) return self.transformResult(t, if (hasArgument(args, 1)) 1 else x);
            var spatial = Affine3.fromPlane(t);
            spatial.rows[2][2] = try numeric(args[2]);
            return self.spatialTransform(spatial);
        },
        .rotate => {
            const angle = try angular(args[0]);
            if (!hasArgument(args, 1)) return self.transformResult(.rotation(angle), 1);
            if (args[1] != .vec3 or !args[1].vec3.dimension.eql(.scalar)) return error.InvalidAxis;
            return self.spatialTransform(try Affine3.rotation(angle, try args[1].vec3.points()));
        },
        .compose => {
            const first = try self.affineValue(args[0]);
            const second = try self.affineValue(args[1]);
            if (first == .plane and second == .plane)
                return self.transformResult(first.plane.xy.then(second.plane.xy), first.plane.z_scale * second.plane.z_scale);
            return self.spatialTransform(first.matrix3().then(second.matrix3()));
        },
        .apply => {
            if (args[1] == .vec3) {
                const p = args[1].vec3;
                const v = (try self.affineValue(args[0])).matrix3().apply(try p.points());
                return .{ .vec3 = try types.Vec3.fromPoints(v, p.dimension) };
            }
            const result = (try self.transformValue(args[0])).apply(try point(args[1]));
            const original = try vector(args[1]);
            return .{ .vec2 = if (original.dimension.eql(.scalar)) .{ .x = result.x, .y = result.y } else types.Vec2.fromPoint(result) };
        },
        .bezier, .rectangle, .circle, .ellipse, .arc, .path, .smooth => return self.constructPath(id, args),
        .compound => {
            var combined = Path.init(own);
            errdefer combined.deinit();
            for (try sequence(args[0])) |item| {
                if (item.valueType() != .path) {
                    self.native_message = "compound requires path elements";
                    return error.TypeMismatch;
                }
                try combined.append(try self.path(item));
            }
            return self.pathResult(combined);
        },
        .contour_ranges => {
            const ranges = try (try self.path(args[0])).contourRanges(self.gpa);
            defer self.gpa.free(ranges);
            const rows = try a.alloc(Value, ranges.len);
            for (rows, ranges) |*row, range| row.* = types.listView(try a.dupe(Value, &.{
                .{ .number = range.begin }, .{ .number = range.end }, .{ .boolean = range.closed },
            }));
            return types.listView(rows);
        },
        .subpaths => {
            const parts = try (try self.path(args[0])).subpaths(own);
            defer own.free(parts);
            errdefer for (parts) |*part| part.deinit();
            const values = try a.alloc(Value, parts.len);
            errdefer a.free(values);
            try self.path_values.ensureUnusedCapacity(own, parts.len);
            for (parts, values) |part, *value| {
                value.* = handle(.path, self.path_values.items.len);
                self.path_values.appendAssumeCapacity(part);
            }
            return types.listView(values);
        },
        .reverse, .closed => {
            if (args[0].valueType() == .shape)
                return self.modelResult(if (id == .reverse) .reverse else .closed, args);
            if (id == .reverse) return self.pathResult(try (try self.path(args[0])).reverse(own));
            var result = try (try self.path(args[0])).clone(own);
            errdefer result.deinit();
            try result.close();
            return self.pathResult(result);
        },
        .mapped => return error.CallbackUnavailable,
        .bent => {
            var bend = try transform_geometry.Bend.init(self.gpa, try self.path(args[1]), if (hasArgument(args, 2)) try lengthPoints(args[2]) else 0, if (hasArgument(args, 3)) try lengthPoints(args[3]) else 1e-3);
            defer bend.deinit();
            if (args[0].valueType() == .path) return self.pathResult(try bend.path(own, try self.path(args[0])));
            var source = try self.objectSnapshot(args[0], true);
            defer source.deinit();
            return self.objectResult(try bend.picture(self.scene_allocator, &source.picture));
        },
        .measure => {
            var measure = try Measure.init(self.gpa, try self.path(args[0]), .{ .tolerance = if (hasArgument(args, 1)) try lengthPoints(args[1]) else 1e-3 });
            errdefer measure.deinit();
            return self.store(Measure, &self.measures, measure, .measure);
        },
        .transformed => {
            if (args[0].valueType() == .shape or (args[0].valueType() == .path and (try self.affineValue(args[1])) == .spatial))
                return self.modelResult(.transformed, args);
            const transform = try self.transformValue(args[1]);
            if (args[0].valueType() == .pen) {
                var value = try self.penValue(args[0]);
                const retained = try (try value.fixedNib()).transformed(own, transform);
                value.nib = retained.nib;
                return self.store(DisplayList.Pen, &self.pens, value, .pen);
            }
            if (args[0] == .object) return self.transformedObject(args[0], transform);
            return self.pathResult(try (try self.path(args[0])).transformed(own, transform));
        },
        .joined => {
            if (args[0].valueType() == .shape or args[1].valueType() == .shape)
                return self.modelResult(.joined, args);
            var result = try (try self.path(args[0])).clone(own);
            try result.join(try self.path(args[1]));
            return self.pathResult(result);
        },
        .trimmed => return self.pathResult(try (try self.path(args[0])).trimmed(own, try numeric(args[1]), try numeric(args[2]))),
        .point_at, .tangent_at => {
            const curve = try (try self.path(args[0])).curveAt(try numeric(args[1]));
            return .{ .vec2 = types.Vec2.fromPoint(if (id == .point_at) curve.curve.at(curve.t) else curve.curve.derivative(curve.t)) };
        },
        .arclength, .sample_path, .sample_at_length, .sample_at_fraction, .samples_at_length => {
            var options: Measure.Options = .{};
            const tolerance_index: usize = if (id == .arclength) 1 else 2;
            if (hasArgument(args, tolerance_index)) options.tolerance = try lengthPoints(args[tolerance_index]);
            var temporary: ?Measure = null;
            defer if (temporary) |*value| value.deinit();
            const measure = if (args[0].valueType() == .measure) measured: {
                if (hasArgument(args, tolerance_index)) return error.MeasurementToleranceIsFixed;
                break :measured self.measures.items[try checkedIndex(args[0], .measure, self.measures.items.len)];
            } else measured: {
                temporary = try Measure.init(self.gpa, try self.path(args[0]), options);
                break :measured temporary.?;
            };
            if (id == .arclength) return lengthResult(measure.length);
            if (id == .sample_at_length) return sampleValue(a, try sampleAtLength(measure, args[1]));
            if (id == .sample_at_fraction) return sampleValue(a, try measure.sampleNormalized(try numeric(args[1])));
            if (id == .samples_at_length) {
                const distances = try sequence(args[1]);
                if (distances.len > options.max_segments) return error.GeometryWorkLimit;
                const rows = try a.alloc(Value, distances.len);
                for (rows, distances) |*row, distance| row.* = try sampleValue(a, try sampleAtLength(measure, distance));
                return types.listView(rows);
            }
            const count = if (args[1] == .int) std.math.cast(usize, args[1].int) orelse return error.InvalidSampleCount else return error.TypeMismatch;
            if (count < 2) return error.InvalidSampleCount;
            const samples = try measure.samples(self.gpa, count);
            defer self.gpa.free(samples);
            const rows = try a.alloc(Value, samples.len);
            for (rows, samples) |*row, sample| row.* = try sampleValue(a, sample);
            return types.listView(rows);
        },
        .profile_outline => {
            const position_values = try sequence(args[1]);
            const width_values = try sequence(args[2]);
            if (position_values.len != width_values.len) return error.InvalidProfile;
            const positions = try self.gpa.alloc(f64, position_values.len);
            defer self.gpa.free(positions);
            const widths = try self.gpa.alloc(f64, width_values.len);
            defer self.gpa.free(widths);
            for (positions, position_values) |*out, value| out.* = try numeric(value);
            for (widths, width_values) |*out, value| out.* = try lengthPoints(value);
            var options: regions.Options = .{};
            if (hasArgument(args, 3)) options.cap = std.meta.stringToEnum(regions.Cap, try string(args[3])) orelse return error.InvalidCap;
            if (hasArgument(args, 4)) options.join = std.meta.stringToEnum(regions.Join, try string(args[4])) orelse return error.InvalidJoin;
            if (hasArgument(args, 5)) options.miter_limit = try numeric(args[5]);
            if (hasArgument(args, 6)) options.tolerance = try lengthPoints(args[6]);
            return self.pathResult(try pen_geometry.profileOutline(own, try self.path(args[0]), positions, widths, options));
        },
        .bounds => {
            const box = switch (args[0].valueType()) {
                .path => (try self.path(args[0])).bounds(),
                .object, .picture => value: {
                    var selected = try self.objectSnapshot(args[0], false);
                    defer selected.deinit();
                    break :value try renderer.bounds(&selected.picture, self.frames.items);
                },
                else => return error.TypeMismatch,
            } orelse return types.listView(&.{});
            return types.listView(try a.dupe(Value, &.{ .{ .vec2 = types.Vec2.fromPoint(box.min) }, .{ .vec2 = types.Vec2.fromPoint(box.max) } }));
        },
        .intersections, .intersection_times => {
            const first = try self.path(args[0]);
            const second = try self.path(args[1]);
            const tolerance = if (hasArgument(args, 2)) try lengthPoints(args[2]) else 1e-8;
            return if (id == .intersection_times) self.intersections(a, first, second, tolerance, true) else self.intersections(a, first, second, tolerance, false);
        },
        .path_crossings => {
            const values = try sequence(args[0]);
            if (values.len > 65536) return error.GeometryWorkLimit;
            const curves = try self.gpa.alloc(Path, values.len);
            defer self.gpa.free(curves);
            for (curves, values) |*curve, value| curve.* = try self.path(value);
            const tolerance = if (hasArgument(args, 1)) try lengthPoints(args[1]) else 1e-8;
            const crossings = try path_crossings.find(self.gpa, curves, .{ .tolerance = tolerance });
            defer self.gpa.free(crossings);
            const rows = try a.alloc(Value, crossings.len);
            for (rows, crossings) |*row, crossing| row.* = types.listView(try a.dupe(Value, &.{
                .{ .vec2 = types.Vec2.fromPoint(crossing.point) },
                .{ .int = @intCast(crossing.first.path) },
                .{ .int = @intCast(crossing.first.contour) },
                .{ .number = crossing.first.time },
                .{ .int = @intCast(crossing.second.path) },
                .{ .int = @intCast(crossing.second.contour) },
                .{ .number = crossing.second.time },
            }));
            return types.listView(rows);
        },
        .stroke_sections => {
            const values = try sequence(args[2]);
            var options: pen_geometry.StrokeOptions = .{};
            if (hasArgument(args, 3)) options.tolerance = try lengthPoints(args[3]);
            if (values.len > options.max_segments) return error.GeometryWorkLimit;
            const ranges = try self.gpa.alloc(pen_geometry.sections.Range, values.len);
            defer self.gpa.free(ranges);
            for (ranges, values) |*range, value| {
                const fields = try sequence(value);
                if (fields.len != 3 or fields[0] != .int) return error.TypeMismatch;
                range.* = .{
                    .contour = std.math.cast(usize, fields[0].int) orelse return error.InvalidParameter,
                    .begin = try numeric(fields[1]),
                    .end = try numeric(fields[2]),
                };
            }
            const sections = try pen_geometry.sections.extract(self.gpa, own, try self.path(args[0]), try self.penValue(args[1]), ranges, options);
            defer self.gpa.free(sections);
            const rows = try a.alloc(Value, sections.len);
            for (rows, sections) |*row, section| row.* = try self.pathResult(section);
            return types.listView(rows);
        },
        .clipped => return self.pathResult(try (try self.path(args[0])).clippedToRect(own, .{ .min = try point(args[1]), .max = try point(args[2]) })),
        .region => {
            var options: regions.Options = .{};
            if (hasArgument(args, 1)) options.tolerance = try lengthPoints(args[1]);
            if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) {
                self.native_message = "region tolerance must be positive";
                return error.InvalidTolerance;
            }
            var vector_picture = try self.vectorPicture(self.gpa, args[0], .region);
            defer vector_picture.deinit();
            var converted = try region_geometry.extract(self.gpa, &vector_picture, options);
            defer converted.deinit();
            return self.pathResult(try converted.clone(own));
        },
        .region_union, .region_intersection, .region_difference, .region_xor => {
            if (args[0].valueType() == .shape or args[1].valueType() == .shape) {
                if (args.len != 2 or args[0].valueType() != .shape or args[1].valueType() != .shape) return error.ExpectedTwoModelShapes;
                return self.modelResult(switch (id) {
                    .region_union => .fuse,
                    .region_intersection => .common,
                    .region_difference => .cut,
                    else => return error.UnsupportedModelOperation,
                }, args);
            }
            var options: regions.Options = .{};
            if (hasArgument(args, 2)) options.tolerance = try lengthPoints(args[2]);
            if (hasArgument(args, 3)) options.fill_rule = std.meta.stringToEnum(regions.FillRule, try string(args[3])) orelse return error.InvalidFillRule;
            const operation: regions.Operation = switch (id) {
                .region_union => .unite,
                .region_intersection => .intersect,
                .region_difference => .difference,
                .region_xor => .xor,
                else => unreachable,
            };
            return self.pathResult(try regions.combine(own, try self.path(args[0]), try self.path(args[1]), operation, options));
        },
        .fillet => {
            const source = try self.path(args[0]);
            var scalar: [1]f64 = undefined;
            var list: ?[]f64 = null;
            defer if (list) |values| a.free(values);
            const radii: []const f64 = if (args[1] == .list) blk: {
                const values = try sequence(args[1]);
                // A list is per-vertex; one-element lists would be ambiguous
                // with the scalar form, so require the scalar form instead.
                if (values.len < 2) return error.InvalidRadii;
                const converted = try a.alloc(f64, values.len);
                errdefer a.free(converted);
                for (values, converted) |value, *out| out.* = try lengthPoints(value);
                list = converted;
                break :blk converted;
            } else blk: {
                scalar[0] = try lengthPoints(args[1]);
                break :blk &scalar;
            };
            const converted = path_fillet.fillet(own, source, radii) catch |err| {
                switch (err) {
                    error.InvalidRadii => self.native_message = "fillet radii must be one value or one per vertex",
                    error.OpenPath => self.native_message = "fillet requires a closed polygon",
                    error.CurvedSegment => self.native_message = "fillet requires line segments only",
                    error.MultipleContours => self.native_message = "fillet requires exactly one contour",
                    error.InvalidPath, error.TooFewVertices => self.native_message = "fillet requires a polygon with at least three vertices",
                    error.NonFinite => self.native_message = "fillet requires finite polygon coordinates",
                    error.RadiusTooLarge => self.native_message = "fillet radius is too large for adjacent edges",
                    error.DegeneratePolygon, error.DegenerateCorner => self.native_message = "fillet requires a nondegenerate polygon",
                    else => {},
                }
                return err;
            };
            return self.pathResult(converted);
        },
        .offset => {
            var options: regions.Options = .{};
            if (hasArgument(args, 2)) options.join = std.meta.stringToEnum(regions.Join, try string(args[2])) orelse return error.InvalidJoin;
            if (hasArgument(args, 3)) options.miter_limit = try numeric(args[3]);
            if (hasArgument(args, 4)) options.tolerance = try lengthPoints(args[4]);
            if (hasArgument(args, 5)) options.fill_rule = std.meta.stringToEnum(regions.FillRule, try string(args[5])) orelse return error.InvalidFillRule;
            return self.pathResult(try regions.offset(own, try self.path(args[0]), try lengthPoints(args[1]), options));
        },
        .stroke_path => {
            var options: regions.Options = .{};
            if (hasArgument(args, 2)) options.cap = std.meta.stringToEnum(regions.Cap, try string(args[2])) orelse return error.InvalidCap;
            if (hasArgument(args, 3)) options.join = std.meta.stringToEnum(regions.Join, try string(args[3])) orelse return error.InvalidJoin;
            if (hasArgument(args, 4)) options.miter_limit = try numeric(args[4]);
            if (hasArgument(args, 5)) options.tolerance = try lengthPoints(args[5]);
            return self.pathResult(try regions.stroke(own, try self.path(args[0]), try lengthPoints(args[1]), options));
        },
        .clip_region, .clip_lines => {
            var options: regions.Options = .{};
            if (hasArgument(args, 3)) options.tolerance = try lengthPoints(args[3]);
            if (id == .clip_region and hasArgument(args, 4)) options.fill_rule = std.meta.stringToEnum(regions.FillRule, try string(args[4])) orelse return error.InvalidFillRule;
            const source = try self.path(args[0]);
            const rect: g.BBox = .{ .min = try point(args[1]), .max = try point(args[2]) };
            return self.pathResult(if (id == .clip_region) try regions.clipRegion(own, source, rect, options) else try regions.clipLines(own, source, rect, options));
        },
        .canvas => {
            const target = try self.objectValue(args[0], true);
            const settings = try target.owner.scene.settings(target.index);
            const w = try lengthPoints(args[1]);
            const h = try lengthPoints(args[2]);
            try validateCanvas(w, h);
            settings.size = .{ .x = w, .y = h };
            return .unit;
        },
        .append => return self.place(args[0], args[1], if (hasArgument(args, 2)) try self.transformValue(args[2]) else null),
        .radial_fill => {
            const curve = try self.path(args[0]);
            const start = try point(args[1]);
            const radius = try lengthPoints(args[2]);
            if (radius <= 0) return error.InvalidRadius;
            const colors = [_]DisplayList.Color{ try self.color(args[3]), try self.color(args[4]) };
            return self.pathObject(&curve, &.{ .fill = colors[0], .gradient = &.{ .radial_fill = .{ .start = start, .end = .{ .x = start.x + radius, .y = start.y }, .colors = &colors } } }, .{});
        },
        .linear_fill, .linear_stroke => {
            const curve = try self.path(args[0]);
            const start = try point(args[1]);
            const end = try point(args[2]);
            const values = types.sequence(args[3]) orelse return error.TypeMismatch;
            if (values.len < 2) return error.InvalidStyle;
            const colors = try self.gpa.alloc(DisplayList.Color, values.len);
            defer self.gpa.free(colors);
            for (values, colors) |value, *dest| dest.* = try self.color(value);
            const ramp: DisplayList.Gradient.Ramp = .{ .start = start, .end = end, .colors = colors };
            if (id == .linear_fill)
                return self.pathObject(&curve, &.{ .fill = colors[0], .gradient = &.{ .linear_fill = ramp } }, .{});
            var brush = try self.penValue(args[4]);
            brush.color = colors[0];
            return self.pathObject(&curve, &.{ .pen = brush, .gradient = &.{ .linear_stroke = ramp } }, .{});
        },
        .draw, .fill, .filldraw, .label => {
            return switch (id) {
                .draw, .fill, .filldraw => result: {
                    const path_ = try self.path(args[0]);
                    const style: DisplayList.Style = switch (id) {
                        .draw => .{ .pen = if (hasArgument(args, 1)) try self.penValue(args[1]) else .{} },
                        .fill => .{ .fill = if (hasArgument(args, 1)) try self.color(args[1]) else .{} },
                        .filldraw => .{ .fill = try self.color(args[1]), .pen = try self.penValue(args[2]) },
                        else => unreachable,
                    };
                    const transform_index: usize = if (id == .filldraw) 3 else 2;
                    break :result self.pathObject(&path_, &style, if (hasArgument(args, transform_index)) try self.transformValue(args[transform_index]) else .{});
                },
                .label => result: {
                    const i = try checkedIndex(args[0], .text, self.texts.items.len);
                    break :result self.labelObject(@intCast(i), try point(args[1]), if (hasArgument(args, 2)) try self.transformValue(args[2]) else .{});
                },
                else => unreachable,
            };
        },
        .width, .height, .baseline => {
            const metric = (try self.textValue(args[0])).metrics;
            return lengthResult(switch (id) {
                .width => metric.width,
                .height => metric.height,
                .baseline => metric.baseline,
                else => unreachable,
            });
        },
        .outlines => return self.extractOutlines(args[0]),
        .solver => {
            const value = try own.create(constraints.Solver);
            value.* = .init(own, .{});
            return self.store(*constraints.Solver, &self.solvers, value, .solver);
        },
        .unknown => {
            const owner = try checkedIndex(args[0], .solver, self.solvers.items.len);
            return self.store(Variable, &self.variables, .{ .owner = owner, .id = try (try self.mutableSolver(owner)).newScalar() }, .variable);
        },
        .equation => {
            const owner = try checkedIndex(args[0], .solver, self.solvers.items.len);
            const lhs = try self.expr(args[1]);
            const rhs = try self.expr(args[2]);
            if ((lhs.owner != null and lhs.owner != owner) or (rhs.owner != null and rhs.owner != owner)) return error.DifferentSolvers;
            _ = try (try self.mutableSolver(owner)).addEquation(lhs.expression, rhs.expression);
            return .unit;
        },
        .solve => {
            const owner = try checkedIndex(args[0], .solver, self.solvers.items.len);
            // Solving is read-only, but its scratch/output allocations
            // must use this worker's arena even for a borrowed solver.
            var solver = self.solvers.items[owner].*;
            solver.allocator = own;
            const result = try solver.solve();
            return self.store(Solved, &self.solutions, .{ .owner = owner, .solution = result }, .solution);
        },
        .value => {
            const result = self.solutions.items[try checkedIndex(args[0], .solution, self.solutions.items.len)];
            const variable = self.variables.items[try checkedIndex(args[1], .variable, self.variables.items.len)];
            if (result.owner != variable.owner) return error.DifferentSolvers;
            if (result.solution.status == .inconsistent) return error.InconsistentSystem;
            if (variable.id >= result.solution.values.len) return error.InvalidVariable;
            return number(result.solution.values[variable.id] orelse return error.UnderdeterminedVariable);
        },
        .object => {
            if (!hasArgument(args, 0)) return error.InvalidArguments;
            return switch (args[0].valueType()) {
                .path => result: {
                    const curve = try self.path(args[0]);
                    const style: DisplayList.Style = .{
                        .fill = if (hasArgument(args, 1)) try self.color(args[1]) else if (hasArgument(args, 2)) null else .black,
                        .pen = if (hasArgument(args, 2)) try self.penValue(args[2]) else null,
                    };
                    break :result self.pathObject(&curve, &style, .{});
                },
                .text => result: {
                    if (hasArgument(args, 1) or hasArgument(args, 2)) return error.InvalidStyle;
                    const reference = try checkedIndex(args[0], .text, self.texts.items.len);
                    break :result self.labelObject(@intCast(reference), .zero, .{});
                },
                else => {
                    self.native_message = "object source must be a path or text";
                    return error.TypeMismatch;
                },
            };
        },
        .picture => {
            if (hasArgument(args, 0) != hasArgument(args, 1)) return error.InvalidCanvas;
            const size: ?g.Point = if (hasArgument(args, 0)) .{ .x = try lengthPoints(args[0]), .y = try lengthPoints(args[1]) } else null;
            if (size) |value| try validateCanvas(value.x, value.y);
            const owner = try self.gpa.create(SceneOwner);
            errdefer self.gpa.destroy(owner);
            owner.* = .{ .scene = .{ .storage = .init(self.scene_allocator) }, .owner_index = try self.nextOwnerIndex(), .animation_state = .init(self.gpa) };
            errdefer owner.scene.deinit();
            const index = try owner.scene.addPicture(null, .{}, null);
            (try owner.scene.settings(index)).size = size;
            try self.scene_values.append(self.mem(), owner);
            return objectHandle(owner.scene.object(index));
        },
    }
}
fn constructPath(self: *Runtime, id: builtin.Id, args: []const Value) !Value {
    const a = self.mem();
    var result = Path.init(a);
    if (args[0] == .vec3) switch (id) {
        .circle, .ellipse, .arc, .bezier => return self.modelResult(switch (id) {
            .circle => .circle,
            .ellipse => .ellipse,
            .arc => .arc,
            else => .cubic,
        }, args),
        else => {},
    };
    switch (id) {
        .bezier => {
            try result.moveTo(try point(args[0]));
            try result.cubicTo(try point(args[1]), try point(args[2]), try point(args[3]));
        },
        .rectangle => {
            const p = if (args[0] == .vec3) g.Point.zero else try point(args[0]);
            const w = try lengthPoints(args[1]);
            const h = try lengthPoints(args[2]);
            try result.moveTo(p);
            try result.lineTo(p.add(.{ .x = w, .y = 0 }));
            try result.lineTo(p.add(.{ .x = w, .y = h }));
            try result.lineTo(p.add(.{ .x = 0, .y = h }));
            try result.close();
            if (args[0] == .vec3) return self.modelResult(.profile, &.{
                try self.pathResult(result),              args[0],
                .{ .vec3 = .{ .x = 1, .y = 0, .z = 0 } }, .{ .vec3 = .{ .x = 0, .y = 1, .z = 0 } },
            });
        },
        .circle => result = try Path.circle(a, try point(args[0]), try lengthPoints(args[1])),
        .ellipse => {
            const center = try point(args[0]);
            const rx = try lengthPoints(args[1]);
            const ry = try lengthPoints(args[2]);
            if (rx <= 0 or ry <= 0) return error.InvalidParameter;
            result = try Path.circle(a, .zero, 1);
            try result.transform(g.Transform.scaling(rx, ry).then(.translation(center.x, center.y)));
        },
        .arc => result = try Path.arc(a, try point(args[0]), try lengthPoints(args[1]), try angular(args[2]), try angular(args[3])),
        .path, .smooth => {
            const from_list = id == .smooth or types.sequence(args[0]) != null;
            if (id == .path and from_list and args.len > 3) return error.InvalidPath;
            const values = if (from_list) try sequence(args[0]) else args;
            const closed = if (from_list and hasArgument(args, 1)) try boolean(args[1]) else false;
            if (id == .path and values.len != 0 and values[0] == .vec3) {
                if (values.len < 2) return error.TooFewKnots;
                for (values) |v| if (v != .vec3) return error.ExpectedVec3;
                if (from_list and hasArgument(args, 2)) {
                    const joins = try sequence(args[2]);
                    if (joins.len != values.len - @intFromBool(!closed)) return error.InvalidJoinCount;
                    for (joins) |join| if (!std.mem.eql(u8, try string(join), "straight")) return error.HobbyRequiresPlanarPath;
                }
                return self.modelResult(if (closed) .polygon else .polyline, values);
            }
            if (id == .path and from_list and hasArgument(args, 2)) {
                const kinds = try sequence(args[2]);
                const points = try self.gpa.alloc(g.Point, values.len);
                defer self.gpa.free(points);
                const joins = try self.gpa.alloc(path_construct.Join, kinds.len);
                defer self.gpa.free(joins);
                for (points, values) |*out, value| out.* = try point(value);
                for (joins, kinds) |*out, value| out.* = std.meta.stringToEnum(path_construct.Join, try string(value)) orelse return error.InvalidPathJoin;
                result = try path_construct.constructWithScratch(a, self.gpa, points, joins, .{ .closed = closed });
            } else if (id == .path) {
                if (values.len == 0) return error.InvalidPath;
                try result.moveTo(try point(values[0]));
                for (values[1..]) |v| try result.lineTo(try point(v));
                if (closed) try result.close();
            } else {
                const knots = try self.gpa.alloc(hobby.Knot, values.len);
                defer self.gpa.free(knots);
                const tension = if (hasArgument(args, 2)) try numeric(args[2]) else 1;
                for (values, knots) |v, *k| k.* = .{ .point = try point(v), .incoming_tension = tension, .outgoing_tension = tension };
                result = try path_construct.fromKnotsWithScratch(a, self.gpa, knots, .{ .closed = closed });
            }
        },
        else => unreachable,
    }
    return self.pathResult(result);
}
fn expr(self: *Runtime, v: Value) !Expr {
    if (v.valueType() == .variable) {
        const variable = self.variables.items[try checkedIndex(v, .variable, self.variables.items.len)];
        return .{ .owner = variable.owner, .expression = .{ .terms = try self.mem().dupe(constraints.Term, &.{.{ .variable = variable.id, .coefficient = 1 }}) } };
    }
    if (v.valueType() == .linear) return self.expressions.items[try checkedIndex(v, .linear, self.expressions.items.len)];
    return .{ .owner = null, .expression = .number(try numeric(v)) };
}
fn binary(ctx: ?*anyopaque, _: std.mem.Allocator, op: bc.Op, lhs: Value, rhs: Value) !Value {
    const self = from(ctx);
    const left = try self.expr(lhs);
    const right = try self.expr(rhs);
    if (left.owner != null and right.owner != null and left.owner != right.owner) return error.DifferentSolvers;
    var result: Expr = .{ .owner = left.owner orelse right.owner, .expression = .{} };
    const a = self.mem();
    switch (op) {
        .add, .subtract => {
            const terms = try a.alloc(constraints.Term, left.expression.terms.len + right.expression.terms.len);
            @memcpy(terms[0..left.expression.terms.len], left.expression.terms);
            const sign: f64 = if (op == .add) 1 else -1;
            for (right.expression.terms, terms[left.expression.terms.len..]) |t, *out| out.* = .{ .variable = t.variable, .coefficient = t.coefficient * sign };
            result.expression = .{ .constant = left.expression.constant + sign * right.expression.constant, .terms = terms };
        },
        .multiply, .divide => {
            if ((left.owner != null and right.owner != null) or (op == .divide and right.owner != null)) return error.NonlinearExpression;
            const expression = if (left.owner != null) left.expression else right.expression;
            const scalar = if (left.owner != null) right.expression.constant else left.expression.constant;
            if (op == .divide and scalar == 0) return error.DivisionByZero;
            const terms = try a.dupe(constraints.Term, expression.terms);
            for (terms) |*term| term.coefficient = if (op == .divide) term.coefficient / scalar else term.coefficient * scalar;
            result.expression = .{ .constant = if (op == .divide) expression.constant / scalar else expression.constant * scalar, .terms = terms };
        },
        else => return error.UnsupportedOperator,
    }
    if (!std.math.isFinite(result.expression.constant)) return error.NonFinite;
    for (result.expression.terms) |term| if (!std.math.isFinite(term.coefficient)) return error.NonFinite;
    return self.store(Expr, &self.expressions, result, .linear);
}
fn intersections(self: *Runtime, a: std.mem.Allocator, first: Path, second: Path, tolerance: f64, comptime times: bool) !Value {
    const hits = if (times) try first.intersectionDetails(self.gpa, second, tolerance) else try first.intersections(self.gpa, second, tolerance);
    defer self.gpa.free(hits);
    const values = try a.alloc(Value, hits.len);
    for (hits, values) |hit, *value| value.* = .{ .vec2 = if (times) .{ .x = hit.a, .y = hit.b } else types.Vec2.fromPoint(hit) };
    return types.listView(values);
}

fn sampleValue(allocator: std.mem.Allocator, sample: Measure.Sample) !Value {
    return types.listView(try allocator.dupe(Value, &.{
        .{ .number = sample.u },
        .{ .vec2 = types.Vec2.fromPoint(sample.point) },
        .{ .vec2 = .{ .x = sample.tangent.x, .y = sample.tangent.y } },
        .{ .number = sample.time },
        .{ .int = @intCast(sample.contour) },
    }));
}

fn validateCanvas(w: f64, h: f64) !void {
    if (w <= 0 or h <= 0 or !std.math.isFinite(w) or !std.math.isFinite(h)) return error.InvalidCanvas;
}

fn readMotion(a: std.mem.Allocator, input: Value, legacy: bool, tolerance: f64) !*const pen_geometry.Motion {
    const Motion = pen_geometry.Motion;
    const values = try sequence(input);
    const tracks = try a.alloc(Motion.Track, if (legacy) 1 else values.len);
    var keys: std.ArrayList(Motion.Key) = .empty;
    var visits: usize = 0;
    var corner: ?Motion.Corner = null;
    for (tracks, 0..) |*track, i| {
        var stops = values;
        var kind: Motion.Kind = .scale;
        if (!legacy) {
            const op = try sequence(values[i]);
            if (op.len == 0) return error.InvalidMotion;
            kind = std.meta.stringToEnum(Motion.Kind, try string(op[0])) orelse return error.InvalidMotion;
            if (kind == .path_frame) {
                if (op.len > 2) return error.InvalidMotion;
                const mode: Motion.Corner = if (op.len == 1) .strict else std.meta.stringToEnum(Motion.Corner, try string(op[1])) orelse return error.InvalidFrameCorner;
                if (corner != null and corner.? != mode) return error.ConflictingFrameCorners;
                corner = mode;
                track.* = .{ .kind = kind, .first = keys.items.len, .len = 0 };
                continue;
            }
            if (op.len != 2) return error.InvalidMotion;
            const operand = op[1];
            const list = types.sequence(operand);
            if (list == null or (list.?.len > 0 and list.?[0] == .string)) {
                const polynomial = try @import("runtime/pen_polynomial.zig").read(operand, 0, &visits);
                track.* = try polynomial.append(kind, a, &keys);
                continue;
            }
            stops = list.?;
        }
        track.* = .{ .kind = kind, .first = keys.items.len, .len = stops.len };
        try keys.ensureUnusedCapacity(a, stops.len);
        for (stops) |stop| {
            const pair = try sequence(stop);
            if (pair.len != 2) return error.InvalidMotion;
            const v = if (legacy) try lengthPoints(pair[1]) else if (kind == .rotate) try angular(pair[1]) else try numeric(pair[1]);
            keys.appendAssumeCapacity(.{ .t = try numeric(pair[0]), .value = v });
        }
    }
    const motion = try a.create(Motion);
    motion.* = .{ .tracks = tracks, .keys = keys.items, .tolerance = tolerance, .corner = corner orelse .strict };
    try motion.validate();
    return motion;
}

fn handle(kind: Type, id: usize) Value {
    return .{ .handle = .{ .kind = kind, .index = id } };
}

fn checkedIndex(v: Value, kind: Type, count: usize) !usize {
    if (v != .handle or v.handle.kind != kind or v.handle.index >= count) return error.TypeMismatch;
    return v.handle.index;
}

pub fn numeric(v: Value) !f64 {
    return switch (v) {
        .int => |x| @floatFromInt(x),
        .number => |x| x,
        else => error.TypeMismatch,
    };
}

fn number(v: f64) !Value {
    if (!std.math.isFinite(v)) return error.NonFinite;
    return .{ .number = v };
}

fn lengthResult(v: f64) !Value {
    if (!std.math.isFinite(v)) return error.NonFinite;
    return .{ .quantity = units.fromPoints(v) };
}

pub fn lengthPoints(v: Value) !f64 {
    return if (v == .quantity) units.toPoints(v.quantity) else numeric(v);
}

fn sampleAtLength(measure: Measure, distance: Value) !Measure.Sample {
    const points = try lengthPoints(distance);
    // Compare in the caller's canonical units before converting to native
    // distance: a returned length must address its own endpoint exactly.
    if (distance == .quantity and measure.length > 0)
        return measure.sampleNormalized(distance.quantity.value / units.fromPoints(measure.length).value);
    return measure.sample(points);
}

pub fn angular(v: Value) !f64 {
    if (v == .quantity) {
        if (!v.quantity.dimension.eql(.rotation)) return error.DimensionMismatch;
        _ = try v.quantity.checked();
        return v.quantity.value;
    }
    return numeric(v);
}

fn vector(v: Value) !types.Vec2 {
    return if (v == .vec2 and v.vec2.isFinite()) v.vec2 else error.TypeMismatch;
}

fn point(v: Value) !g.Point {
    return switch (v) {
        .vec2 => |p| p.nativePoint(),
        else => error.TypeMismatch,
    };
}

fn boolean(v: Value) !bool {
    return switch (v) {
        .boolean => |x| x,
        else => error.TypeMismatch,
    };
}

fn string(v: Value) ![]const u8 {
    return switch (v) {
        .string => |x| x,
        else => error.TypeMismatch,
    };
}

fn sequence(v: Value) ![]const Value {
    return types.sequence(v) orelse error.TypeMismatch;
}

fn compoundAllocationExercise(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const start: Value = .{ .vec2 = .{ .x = -5, .y = 2 } };
    const end: Value = .{ .vec2 = .{ .x = 5, .y = 7 } };
    const open = try runtime.invoke(a, .path, &.{ start, end });
    const closed = try runtime.invoke(a, .rectangle, &.{ start, .{ .number = 5 }, .{ .number = 8 } });
    const combined = try runtime.invoke(a, .compound, &.{types.listView(&.{ open, closed, open })});
    const segments = (try runtime.path(combined)).segments.items;
    const open_segments = (try runtime.path(open)).segments.items;
    const closed_segments = (try runtime.path(closed)).segments.items;
    try std.testing.expectEqualDeep(open_segments, segments[0..open_segments.len]);
    try std.testing.expectEqualDeep(closed_segments, segments[open_segments.len .. open_segments.len + closed_segments.len]);
    try std.testing.expectEqualDeep(open_segments, segments[open_segments.len + closed_segments.len ..]);
    const empty = try runtime.invoke(a, .compound, &.{types.listView(&.{})});
    try std.testing.expectEqual(@as(usize, 0), (try runtime.path(empty)).segments.items.len);
    const invalid = runtime.invoke(a, .compound, &.{types.listView(&.{ open, .{ .int = 1 } })}) catch |err|
        if (err == error.OutOfMemory) return err else err;
    try std.testing.expectError(error.TypeMismatch, invalid);
    try std.testing.expectEqualStrings("compound requires path elements", runtime.native_message);
}

fn subpathsAllocationExercise(a: std.mem.Allocator) !void {
    var outputs: std.heap.ArenaAllocator = .init(a);
    defer outputs.deinit();
    const out = outputs.allocator();
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const open = try runtime.invoke(out, .bezier, &.{
        .{ .vec2 = .zero },
        .{ .vec2 = .{ .x = 0, .y = 2 } },
        .{ .vec2 = .{ .x = 2, .y = 2 } },
        .{ .vec2 = .{ .x = 2, .y = 0 } },
    });
    const closed = try runtime.invoke(out, .rectangle, &.{ .{ .vec2 = .zero }, .{ .number = 5 }, .{ .number = 8 } });
    const combined = try runtime.invoke(out, .compound, &.{types.listView(&.{ open, closed, open })});
    const parts = try sequence(try runtime.invoke(out, .subpaths, &.{combined}));
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    for (parts, [_]Value{ open, closed, open }) |part, source| {
        const actual = try runtime.path(part);
        const expected = try runtime.path(source);
        try std.testing.expectEqualDeep(expected.segments.items, actual.segments.items);
        try std.testing.expectEqual(expected.open, actual.open);
        try std.testing.expect(actual.segments.items.ptr != expected.segments.items.ptr);
    }
    try std.testing.expect((try runtime.path(parts[0])).segments.items.ptr != (try runtime.path(parts[2])).segments.items.ptr);
    const joined = try runtime.invoke(out, .compound, &.{types.listView(parts)});
    try std.testing.expectEqualDeep((try runtime.path(combined)).segments.items, (try runtime.path(joined)).segments.items);
    const empty = try runtime.invoke(out, .compound, &.{types.listView(&.{})});
    try std.testing.expectEqual(@as(usize, 0), (try sequence(try runtime.invoke(out, .subpaths, &.{empty}))).len);
    try std.testing.expectError(error.TypeMismatch, runtime.invoke(out, .subpaths, &.{.{ .int = 1 }}));
    try std.testing.expect(runtime.engine == null);
}

fn outlineAllocationExercise(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const rectangle = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .number = 5 }, .{ .number = 8 } });
    const result = try runtime.invoke(a, .outlines, &.{rectangle});
    try std.testing.expectEqual(Type.object, result.valueType());
    const host_value = runtime.host();
    const items = try sequence(try host_value.field(a, result, "paths"));
    defer a.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const path_ = try runtime.path(items[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 5), path_.bounds().?.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 8), path_.bounds().?.max.y, 1e-10);
    try std.testing.expect(runtime.engine == null);
    try std.testing.expectError(error.TypeMismatch, runtime.invoke(a, .outlines, &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("outlines requires a path, text, or object", runtime.native_message);
    try std.testing.expectError(error.InvalidTolerance, runtime.invoke(a, .region, &.{ rectangle, .{ .number = 0 } }));
    try std.testing.expectEqualStrings("region tolerance must be positive", runtime.native_message);
}

test "outline results own geometry and pure paths require no Typst engine across OOM" {
    try outlineAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), outlineAllocationExercise, .{});
}

test "outline snapshots preserve original cubic controls styles and independent path storage" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const curve = try runtime.invoke(a, .bezier, &.{
        .{ .vec2 = .{ .x = 0.125, .y = -0.375 } },
        .{ .vec2 = .{ .x = 1.0 / 3.0, .y = 17.0 / 11.0 } },
        .{ .vec2 = .{ .x = 9.0 / 7.0, .y = -3.0 / 13.0 } },
        .{ .vec2 = .{ .x = 2.625, .y = 0.875 } },
    });
    const source = try runtime.path(curve);
    const snapshot = try runtime.invoke(a, .outlines, &.{curve});
    const picture = (try runtime.objectValue(snapshot, false)).owner;
    try std.testing.expectEqualDeep(source.segments.items, picture.scene.storage.segments.items);
    try std.testing.expect(source.segments.items.ptr != picture.scene.storage.segments.items.ptr);
    const host_value = runtime.host();
    const entries = try sequence(try host_value.field(a, snapshot, "paths"));
    defer a.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const returned = try runtime.path(entries[0]);
    try std.testing.expectEqualDeep(source.segments.items, returned.segments.items);
    try std.testing.expectEqual(@as(usize, 1), returned.segmentCount());
    const marker = try runtime.invoke(a, .path, &.{.{ .vec2 = .{ .x = 4, .y = -2 } }});
    const marker_copy = try runtime.invoke(a, .outlines, &.{marker});
    try std.testing.expectEqualDeep((try runtime.path(marker)).segments.items, (try runtime.objectValue(marker_copy, false)).owner.scene.storage.segments.items);
    const marker_region = try runtime.invoke(a, .region, &.{marker});
    try std.testing.expectEqual(@as(usize, 0), (try runtime.path(marker_region)).segments.items.len);
    try std.testing.expect(runtime.engine == null);
}

test "raw vector paths borrow source paints without copying their storage and retain animation guards" {
    const a = std.testing.allocator;
    var tracking = std.testing.FailingAllocator.init(a, .{});
    const counted = tracking.allocator();
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(counted, counted, &unused_library, .{});
    defer runtime.deinit();
    const target = try runtime.invoke(counted, .picture, &.{});
    const original = testOwner(target);
    var curve = Path.init(a);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = -2 }, .{ .x = 5, .y = 0 });
    var dashes: [4096]f64 = @splat(1);
    const drawn = try original.scene.addPath(0, &curve, &.{ .pen = .{ .width = 1, .dash = &dashes } }, .{});
    const before = tracking.allocated_bytes;
    const host_value = runtime.host();
    const entries = try sequence(try host_value.field(counted, target, "paths"));
    defer counted.free(entries);
    // Reading one short curve must not allocate another copy of its much
    // larger paint data. The bound allows normal path/list/arena overhead.
    try std.testing.expect(tracking.allocated_bytes - before < @sizeOf(@TypeOf(dashes)));
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const returned = try runtime.path(entries[0]);
    try std.testing.expectEqualDeep(curve.segments.items, returned.segments.items);
    try std.testing.expect(returned.segments.items.ptr != original.scene.storage.segments.items.ptr);
    try std.testing.expectEqual(@as(usize, 2), original.scene.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.scene_values.items.len);
    try std.testing.expect(runtime.engine == null);
    _ = try runtime.invoke(counted, .timeline, &.{ target, .{ .number = 2 } });
    const id: Value = .{ .object = .{ .owner = original, .index = drawn } };
    _ = try runtime.invoke(counted, .animate, &.{ id, .{ .string = "opacity" }, types.listView(&.{
        types.listView(&.{ .{ .int = 0 }, .{ .number = 0 } }),
        types.listView(&.{ .{ .int = 1 }, .{ .number = 1 } }),
    }) });
    try std.testing.expectError(error.AnimatedPicture, host_value.field(counted, target, "paths"));
    try std.testing.expectEqualStrings("operation requires a static object (including its ancestors and descendants)", runtime.native_message);
}

test "compound preserves ordered subpaths and cleans up each allocation failure" {
    try compoundAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), compoundAllocationExercise, .{});
}

test "subpaths transfers independent paths and caller lists safely across allocation failures" {
    try subpathsAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), subpathsAllocationExercise, .{});
}

test "region clipping fill rule preserves the hole between nested same-direction contours" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const outer = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .{ .x = 0, .y = 0 } }, .{ .number = 10 }, .{ .number = 10 } });
    const inner = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .{ .x = 2, .y = 2 } }, .{ .number = 6 }, .{ .number = 6 } });
    var compound = try (try runtime.path(outer)).clone(runtime.mem());
    try compound.append(try runtime.path(inner));
    const nested = try runtime.pathResult(compound);
    const min: Value = .{ .vec2 = .{ .x = -1, .y = -1 } };
    const max: Value = .{ .vec2 = .{ .x = 11, .y = 11 } };
    const solid = try runtime.invoke(a, .clip_region, &.{ nested, min, max });
    const ring = try runtime.invoke(a, .clip_region, &.{ nested, min, max, .{ .number = 0.001 }, .{ .string = "evenodd" } });
    var solid_contours: usize = 0;
    for ((try runtime.path(solid)).segments.items) |segment| {
        if (segment == .close) solid_contours += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), solid_contours);
    var contours: usize = 0;
    var holes: usize = 0;
    var area: f64 = 0;
    var contour_area: f64 = 0;
    var first = g.Point.zero;
    var previous = g.Point.zero;
    for ((try runtime.path(ring)).segments.items) |segment| switch (segment) {
        .move => |p| {
            first = p;
            previous = p;
            contour_area = 0;
        },
        .line => |p| {
            contour_area += previous.cross(p);
            previous = p;
        },
        .close => {
            contour_area += previous.cross(first);
            area += contour_area * 0.5;
            contours += 1;
            if (contour_area < 0) holes += 1;
        },
        .cubic => return error.UnexpectedCurve,
    };
    try std.testing.expectEqual(@as(usize, 2), contours);
    try std.testing.expectEqual(@as(usize, 1), holes);
    try std.testing.expectApproxEqAbs(@as(f64, 64), area, 1e-7);
}

test "module Typst setups stay independent while switching the active file" {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(std.testing.allocator, std.testing.allocator, &unused_library, .{});
    defer runtime.deinit();
    try std.testing.expectEqualStrings("", runtime.moduleSetup());
    try Runtime.setupBlock(&runtime, "set text(size: 10pt)");
    const root_setup = runtime.moduleSetup();
    try Runtime.selectModule(&runtime, 2);
    try std.testing.expectEqualStrings("", runtime.moduleSetup());
    try Runtime.setupBlock(&runtime, "set text(size: 30pt)");
    const child_setup = runtime.moduleSetup();
    try Runtime.selectModule(&runtime, 0);
    try std.testing.expectEqualStrings(root_setup, runtime.moduleSetup());
    try Runtime.selectModule(&runtime, 1);
    try std.testing.expectEqualStrings("", runtime.moduleSetup());
    try Runtime.selectModule(&runtime, 2);
    try std.testing.expectEqualStrings(child_setup, runtime.moduleSetup());
}

test "native geometry converts physical lengths while vector arithmetic retains dimensions" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const cm: Value = .{ .quantity = try units.applyUnit(1, .cm) };
    const centre = try numeric_ops.makeVec2(cm, .{ .int = 0 });
    const canvas = try runtime.invoke(a, .picture, &.{ cm, cm });
    try std.testing.expectApproxEqAbs(@as(f64, 720.0 / 25.4), (try testOwner(canvas).scene.settings(canvas.object.index)).size.?.x, 1e-12);
    const curve = try runtime.invoke(a, .circle, &.{ centre, cm });
    const result = (try runtime.path(curve)).bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 1440.0 / 25.4), result.max.x, 1e-12);
    const unit = try runtime.invoke(a, .unit, &.{centre});
    try std.testing.expect(unit.vec2.dimension.eql(.scalar));
    try std.testing.expectApproxEqAbs(@as(f64, 1), unit.vec2.x, 1e-12);
    const norm = try runtime.invoke(a, .norm, &.{centre});
    try std.testing.expectEqual(cm.quantity, norm.quantity);
    const dot = try runtime.invoke(a, .dot, &.{ centre, centre });
    try std.testing.expectEqual(units.Dimension{ .length = 2 }, dot.quantity.dimension);
    const sqrt = try runtime.invoke(a, .sqrt, &.{dot});
    try std.testing.expectEqual(cm.quantity, sqrt.quantity);
    const radians = try runtime.invoke(a, .atan2, &.{ cm, cm });
    try std.testing.expect(radians.quantity.dimension.eql(.rotation));
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 4.0), radians.quantity.value, 1e-12);
    const midpoint = try runtime.invoke(a, .lerp, &.{ cm, .{ .quantity = try units.applyUnit(2, .cm) }, .{ .number = 0.5 } });
    try std.testing.expectEqual(@as(f64, 15), midpoint.quantity.value);
    try std.testing.expectError(error.DimensionMismatch, runtime.invoke(a, .min, &.{ cm, radians }));
    try std.testing.expectError(error.DimensionMismatch, runtime.invoke(a, .rotate, &.{cm}));
}

test "explicit nib animations preserve transform tracks and reject unnormalized stroke tracks" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const picture = try runtime.invoke(a, .picture, &.{});
    const path_value = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const nib = try runtime.invoke(a, .pencircle, &.{.{ .int = 3 }});
    const id = try runtime.invoke(a, .append, &.{ picture, try runtime.invoke(a, .draw, &.{ path_value, nib }) });
    const scalar_keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) });
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .animate, &.{ id, .{ .string = "stroke_width" }, scalar_keys }));
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .animate, &.{ id, .{ .string = "path" }, scalar_keys }));
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .animate, &.{ id, .{ .string = "stroke" }, scalar_keys }));
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .animate, &.{ id, .{ .string = "fill" }, scalar_keys }));
    const target = (try runtime.objectValue(id, false)).owner;
    try std.testing.expectEqual(@as(usize, 0), target.animation_state.tracks.len());
    _ = try runtime.invoke(a, .animate, &.{ id, .{ .string = "opacity" }, scalar_keys });
    try std.testing.expectEqual(@as(usize, 1), target.animation_state.tracks.len());
    const group = try runtime.invoke(a, .append, &.{ picture, try runtime.invoke(a, .picture, &.{ .omitted, .omitted, try runtime.invoke(a, .scale, &.{.{ .int = 1 }}) }) });
    _ = try runtime.invoke(a, .append, &.{ group, try runtime.invoke(a, .draw, &.{ path_value, nib }) });

    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .animate, &.{ group, .{ .string = "stroke_width" }, scalar_keys }));
}

test "animated ancestors constrain placed subtrees and style changes without rejecting transform tracks" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const picture = try runtime.invoke(a, .picture, &.{});
    const transform = try runtime.invoke(a, .scale, &.{.{ .int = 1 }});
    const group = try runtime.invoke(a, .append, &.{ picture, try runtime.invoke(a, .picture, &.{ .omitted, .omitted, transform }) });
    const keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 1 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 2 } }) });
    _ = try runtime.invoke(a, .animate, &.{ group, .{ .string = "stroke_width" }, keys });
    const path_value = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const nib = try runtime.invoke(a, .pensquare, &.{.{ .int = 3 }});
    const ordinary = try runtime.invoke(a, .append, &.{ group, try runtime.invoke(a, .draw, &.{path_value}) });
    const scene = &(try runtime.objectValue(ordinary, false)).owner.scene;
    const previous = (try scene.getNode(ordinary.object.index)).path.style;
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .object_style, &.{ ordinary, .omitted, nib }));
    try std.testing.expectEqualDeep(previous, (try scene.getNode(ordinary.object.index)).path.style);
    const rejected = try runtime.invoke(a, .draw, &.{ path_value, nib });
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .append, &.{ group, rejected }));
    const target = (try runtime.objectValue(group, false)).owner;
    try std.testing.expectEqual(@as(usize, 1), target.animation_state.tracks.len());

    try std.testing.expect((try (try runtime.objectValue(rejected, false)).owner.scene.parentObject(rejected.object.index)) == null);
    const nested = try runtime.invoke(a, .append, &.{ group, try runtime.invoke(a, .picture, &.{}) });
    const source = try runtime.invoke(a, .picture, &.{});
    _ = try runtime.invoke(a, .append, &.{ source, rejected });
    try std.testing.expectError(error.UnsupportedNibAnimation, runtime.invoke(a, .append, &.{ nested, source }));
    try std.testing.expect((try testOwner(source).scene.parentObject(source.object.index)) == null);
    try std.testing.expect((try testOwner(rejected).scene.parentObject(rejected.object.index)).?.eql(testOwner(source).scene.object(source.object.index)));
    const moving = try runtime.invoke(a, .picture, &.{});
    _ = try runtime.invoke(a, .animate, &.{ moving, .{ .string = "rotate" }, keys });
    _ = try runtime.invoke(a, .append, &.{ moving, source });
    try std.testing.expect((try testOwner(source).scene.parentObject(source.object.index)).?.eql(testOwner(moving).scene.object(moving.object.index)));
    try std.testing.expect(testOwner(source).hasGeometricStroke(source.object.index));
    var selected = try target.view(a, group.object.index);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.tracks.items.len);
}

test "pictures keep dimensions children and stable aliases independent" {
    const a = std.testing.allocator;
    // These operations use only the Zig engine and never access native code.
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const first = try runtime.invoke(a, .picture, &.{ .{ .int = 640 }, .{ .int = 480 } });
    const second = try runtime.invoke(a, .picture, &.{ .{ .int = 200 }, .{ .int = 100 } });
    const host_value = runtime.host();
    try std.testing.expectEqual(@as(f64, 640), try lengthPoints(try host_value.field(a, first, "width")));
    try std.testing.expectEqual(@as(f64, 480), try lengthPoints(try host_value.field(a, first, "height")));
    _ = try runtime.invoke(a, .timeline, &.{ first, .{ .number = 2 } });
    try std.testing.expect(!(try host_value.field(a, first, "animated")).boolean);
    try std.testing.expectError(error.UnknownField, host_value.field(a, first, "baseline"));
    try std.testing.expectError(error.UnknownField, host_value.field(a, first, "root"));
    try std.testing.expect(runtime.engine == null);
    const first_target = testOwner(first);
    try std.testing.expectEqual(@as(f64, 640), (try first_target.scene.settings(first.object.index)).size.?.x);
    try std.testing.expectEqual(@as(f64, 480), (try first_target.scene.settings(first.object.index)).size.?.y);
    _ = try runtime.invoke(a, .canvas, &.{ second, .{ .int = 300 }, .{ .int = 150 } });
    try std.testing.expectEqual(@as(f64, 300), (try testOwner(second).scene.settings(second.object.index)).size.?.x);
    try std.testing.expectEqual(@as(f64, 640), (try first_target.scene.settings(first.object.index)).size.?.x);
    const curve = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const first_object = try runtime.invoke(a, .append, &.{ first, try runtime.invoke(a, .draw, &.{curve}) });
    const alias = first;
    const second_object = try runtime.invoke(a, .append, &.{ alias, try runtime.invoke(a, .draw, &.{curve}) });
    try std.testing.expect(!std.meta.eql(first_object.object, second_object.object));
    try std.testing.expectEqual(@as(usize, 0), first_target.animation_state.targets.items.len);
    try std.testing.expectEqual(@as(usize, 3), try testChildCount(first) + 1);
    try std.testing.expectEqual(@as(usize, 0), try testChildCount(second));
    // Growing the owner table cannot move a target that is already borrowed.
    for (0..100) |_| _ = try runtime.invoke(a, .picture, &.{});
    try std.testing.expectEqual(first_target, testOwner(first));
    _ = try runtime.invoke(a, .append, &.{ first, try runtime.invoke(a, .draw, &.{curve}) });
    const keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) });
    _ = try runtime.invoke(a, .animate, &.{ first_object, .{ .string = "opacity" }, keys });
    _ = try runtime.invoke(a, .animate, &.{ second_object, .{ .string = "opacity" }, keys });
    const state = &(try runtime.objectValue(first_object, false)).owner.animation_state;
    var tracks = state.iterator();
    try std.testing.expectEqual(@as(u64, first_object.object.index + 1), tracks.next().?.target);
    try std.testing.expectEqual(@as(u64, second_object.object.index + 1), tracks.next().?.target);
    try std.testing.expectError(error.ConflictingTracks, runtime.invoke(a, .animate, &.{ first_object, .{ .string = "opacity" }, keys }));
    const invalid: Value = .{ .object = .{ .owner = first_target, .index = 999 } };
    // Target validation precedes malformed property/path and key diagnostics.
    try std.testing.expectError(error.InvalidObject, runtime.invoke(a, .animate, &.{ invalid, .{ .int = 0 }, .{ .int = 0 } }));
    try std.testing.expectError(error.InvalidObject, runtime.invoke(a, .motion, &.{ invalid, .{ .int = 0 }, .{ .int = 0 } }));
    try std.testing.expectEqual(@as(usize, 4), try testChildCount(first) + 1);
    try std.testing.expectEqual(@as(usize, 0), try testChildCount(second));
    try std.testing.expectError(error.InvalidCanvas, runtime.invoke(a, .picture, &.{.{ .int = 0 }}));
    try std.testing.expectError(error.TypeMismatch, runtime.invoke(a, .append, &.{ curve, try runtime.invoke(a, .draw, &.{curve}) }));
    try std.testing.expectError(error.ExpectedPicture, runtime.invoke(a, .append, &.{ first_object, second_object }));
    try std.testing.expectError(error.TypeMismatch, runtime.render(curve, .svg));
    try std.testing.expectError(error.ExpectedPicture, runtime.render(first_object, .svg));
}

test "object placement preserves handles geometry and animation across canvases" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const first = try runtime.invoke(a, .picture, &.{});
    const second = try runtime.invoke(a, .picture, &.{});
    const curve = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const item = try runtime.invoke(a, .draw, &.{curve});
    const instance = try runtime.objectValue(item, false);
    const geometry = instance.owner.scene.storage.segments.items.ptr;
    const keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) });
    _ = try runtime.invoke(a, .animate, &.{ item, .{ .string = "opacity" }, keys });
    _ = try runtime.invoke(a, .timeline, &.{ first, .{ .int = 2 } });
    _ = try runtime.invoke(a, .timeline, &.{ second, .{ .int = 3 } });
    try std.testing.expectEqualDeep(item, try runtime.invoke(a, .append, &.{ first, item }));
    try std.testing.expectEqualDeep(item, try runtime.invoke(a, .append, &.{ first, item }));
    try std.testing.expectEqual(@as(usize, 1), try testChildCount(first));
    _ = try runtime.invoke(a, .append, &.{ second, item });
    try std.testing.expectEqual(geometry, instance.owner.scene.storage.segments.items.ptr);
    try std.testing.expectEqual(@as(usize, 0), try testChildCount(first));
    var old = try testOwner(first).view(a, first.object.index);
    defer old.deinit();
    var moved = try testOwner(second).view(a, second.object.index);
    defer moved.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 1), moved.tracks.items.len);
    try std.testing.expectEqual(@as(f64, 3), (try moved.animation()).?.duration_seconds);
}

fn testChildCount(value: Value) !usize {
    var children = try testOwner(value).scene.children(value.object.index);
    var count: usize = 0;
    while (children.next() != null) count += 1;
    return count;
}

fn pictureAllocationScenario(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var scene_allocator = std.testing.FailingAllocator.init(a, .{});
    defer std.debug.assert(scene_allocator.allocated_bytes == scene_allocator.freed_bytes);
    var runtime = try Runtime.init(a, scene_allocator.allocator(), &unused_library, .{});
    defer runtime.deinit();
    const first = try runtime.invoke(a, .picture, &.{});
    const second = try runtime.invoke(a, .picture, &.{});
    const curve = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    for (0..5) |_| {
        _ = try runtime.invoke(a, .append, &.{ first, try runtime.invoke(a, .draw, &.{curve}) });
    }
    _ = try runtime.invoke(a, .append, &.{ second, first });
    const transform = try runtime.transformResult(.translation(4, 7), 1);
    _ = try runtime.invoke(a, .transformed, &.{ first, transform });
    _ = try runtime.invoke(a, .snapshot, &.{first});
    const clip = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .int = 10 }, .{ .int = 10 } });
    _ = try runtime.invoke(a, .object_clip, &.{ first, clip });
    _ = try runtime.invoke(a, .object_reset_clip, &.{first});
    try std.testing.expectEqual(@as(usize, 5), try testChildCount(first));
}

test "clip intersects the root scope and reset clears every accumulated path" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const picture = try runtime.invoke(a, .picture, &.{});
    const left = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .int = 10 }, .{ .int = 20 } });
    const top = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .int = 20 }, .{ .int = 10 } });
    const outside = try runtime.invoke(a, .rectangle, &.{ .{ .vec2 = .{ .x = 100, .y = 100 } }, .{ .int = 10 }, .{ .int = 10 } });
    const owner = testOwner(picture);
    const node = try owner.scene.getNode(picture.object.index);

    _ = try runtime.invoke(a, .object_clip, &.{ picture, left });
    try std.testing.expect(node.picture.clip != null);
    const first_count = node.picture.clip.?.count;
    try std.testing.expect(first_count != 0);

    _ = try runtime.invoke(a, .object_clip, &.{ picture, top });
    try std.testing.expect(node.picture.clip != null);
    try std.testing.expect(node.picture.clip.?.count != 0);

    _ = try runtime.invoke(a, .object_reset_clip, &.{picture});
    try std.testing.expect(node.picture.clip == null);

    _ = try runtime.invoke(a, .object_clip, &.{ picture, outside });
    _ = try runtime.invoke(a, .object_clip, &.{ picture, left });
    try std.testing.expect(node.picture.clip != null);
    try std.testing.expectEqual(@as(usize, 0), node.picture.clip.?.count);

    _ = try runtime.invoke(a, .object_reset_clip, &.{picture});
    try std.testing.expect(node.picture.clip == null);
}

test "picture owners release all resources when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pictureAllocationScenario, .{});
}

fn penSnapshotAllocationScenario(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const points = [_]g.Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
    const brush = try runtime.store(DisplayList.Pen, &runtime.pens, .{ .dash = &.{ 3, 2 }, .nib = .{ .polygon = &points } }, .pen);
    const curve = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const item = try runtime.invoke(a, .draw, &.{ curve, brush });
    const host_value = runtime.host();
    const saved = try host_value.field(a, item, "pen");
    const replacement = try runtime.store(DisplayList.Pen, &runtime.pens, .{}, .pen);
    _ = try runtime.invoke(a, .object_style, &.{ item, .omitted, replacement });
    const pen = try runtime.penValue(saved);
    try std.testing.expectEqualSlices(f64, &.{ 3, 2 }, pen.dash);
    try std.testing.expectEqualSlices(g.Point, &points, pen.nib.?.polygon);
    _ = try runtime.invoke(a, .draw, &.{ curve, saved });
}

test "queried pens retain dash and nib snapshots after source style replacement across OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, penSnapshotAllocationScenario, .{});
}

pub const FormatError = std.mem.Allocator.Error || error{ ValueNestingTooDeep, ValueFormattingLimit, InvalidValue };
const SequenceIdentity = struct { address: usize, len: usize = 0, kind: enum { list, dict, record } = .list };
/// Bound native work performed by one VM instruction. Lists may share nested
/// values, so a small input graph can otherwise expand into unbounded output.
pub fn formatValue(a: std.mem.Allocator, value: Value) FormatError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var remaining: usize = 100_000;
    var ancestors: [257]?SequenceIdentity = @splat(null);
    try appendValue(a, &result, value, 0, &remaining, &ancestors);
    return result.toOwnedSlice(a);
}

test "aggregate runtime formatting marks mixed cycles and preserves dictionary order" {
    const a = std.testing.allocator;
    var dict: types.Dict = .{};
    defer dict.entries.deinit(a);
    var fields = [_]Value{.{ .dict = &dict }};
    var record_value: types.Record = .{ .kind = Type.record(0), .fields = &fields };
    try dict.entries.put(a, "tag", .{ .int = 1 });
    try dict.entries.put(a, "cycle", .{ .record = &record_value });
    const rendered = try formatValue(a, .{ .dict = &dict });
    defer a.free(rendered);
    try std.testing.expectEqualStrings("{\"tag\": 1, \"cycle\": struct{{...}}}", rendered);
    try std.testing.expectError(error.InvalidValue, formatValue(a, .omitted));
    var escaped: types.Dict = .{};
    defer escaped.entries.deinit(a);
    try escaped.entries.put(a, "quote\"\\\n", .unit);
    const quoted = try formatValue(a, .{ .dict = &escaped });
    defer a.free(quoted);
    try std.testing.expectEqualStrings("{\"quote\\\"\\\\\\n\": ()}", quoted);
}

test "aggregate runtime formatting enforces the existing graph budget and releases allocations" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator, value: Value) !void {
            const text = try formatValue(allocator, value);
            defer allocator.free(text);
        }
    };
    var dict: types.Dict = .{};
    defer dict.entries.deinit(std.testing.allocator);
    try dict.entries.put(std.testing.allocator, "self", .{ .dict = &dict });
    try dict.entries.put(std.testing.allocator, "list", types.listView(&.{ .{ .int = 1 }, .{ .int = 2 } }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{Value{ .dict = &dict }});
    var doubled: [20][2]Value = undefined;
    for (&doubled, 0..) |*level, index| level.* = if (index == 0) .{ .unit, .unit } else .{ types.listView(&doubled[index - 1]), types.listView(&doubled[index - 1]) };
    try std.testing.expectError(error.ValueFormattingLimit, formatValue(std.testing.allocator, types.listView(&doubled[doubled.len - 1])));
}

test "aggregate runtime sparse optional builtin slots retain host defaults" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const red = try runtime.invoke(a, .rgb, &.{ .{ .int = 1 }, .{ .int = 0 }, .{ .int = 0 }, .omitted });
    try std.testing.expectEqual(@as(f64, 1), (try runtime.color(red)).a);
    const default_pen = try runtime.penValue(try runtime.invoke(a, .pen, &.{red}));
    const brush = try runtime.penValue(try runtime.invoke(a, .pen, &.{ red, .omitted, .omitted, .{ .string = "round" }, .omitted, .omitted, .omitted, .omitted }));
    try std.testing.expectEqual(default_pen.width, brush.width);
    try std.testing.expectEqual(default_pen.cap, brush.cap);
    try std.testing.expectEqual(default_pen.miter_limit, brush.miter_limit);
    try std.testing.expectEqual(DisplayList.Join.round, brush.join);
    const first_stop = types.listView(&.{ .{ .int = 0 }, .{ .int = 2 } });
    const last_stop = types.listView(&.{ .{ .int = 1 }, .{ .int = 12 } });
    var profile_args = [_]Value{ red, .omitted, .omitted, .omitted, .omitted, .omitted, .omitted, .omitted, types.listView(&.{ first_stop, last_stop }) };
    const pressure = try runtime.penValue(try runtime.invoke(a, .pen, &profile_args));
    try std.testing.expectEqual(@as(f64, 12), pressure.motion.?.keys[1].value);
    profile_args[8] = types.listView(&.{ first_stop, first_stop, last_stop });
    try std.testing.expectError(error.InvalidProfile, runtime.invoke(a, .pen, &profile_args));
    profile_args[8] = types.listView(&.{ first_stop, last_stop });
    profile_args[5] = types.listView(&.{.{ .int = 3 }});
    try std.testing.expectError(error.InvalidPen, runtime.invoke(a, .pen, &profile_args));
    const circle = try runtime.penValue(try runtime.invoke(a, .pencircle, &.{ .omitted, red }));
    try std.testing.expectEqual(DisplayList.Color{ .r = 1, .g = 0, .b = 0 }, circle.color);
    try std.testing.expectEqual(g.Transform{}, circle.nib.?.ellipse);
    const square = try runtime.penValue(try runtime.invoke(a, .pensquare, &.{ .omitted, red }));
    try std.testing.expectEqualSlices(g.Point, pen_geometry.Nib.square().polygon, square.nib.?.polygon);
    const scale = try runtime.transformValue(try runtime.invoke(a, .scale, &.{ .{ .int = 3 }, .omitted }));
    try std.testing.expectEqual(g.Transform.scaling(3, 3), scale);
    try std.testing.expectError(error.InvalidCanvas, runtime.invoke(a, .picture, &.{ .omitted, .{ .int = 123 } }));
    const target = try runtime.invoke(a, .picture, &.{ .{ .int = 640 }, .{ .int = 123 }, .omitted, .omitted });
    try std.testing.expectEqual(@as(f64, 640), (try testOwner(target).scene.settings(target.object.index)).size.?.x);
    try std.testing.expectEqual(@as(f64, 123), (try testOwner(target).scene.settings(target.object.index)).size.?.y);
    const curve = try runtime.invoke(a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const shifted = try runtime.transformResult(.translation(5, 6), 1);
    const item = try runtime.invoke(a, .append, &.{ target, try runtime.invoke(a, .draw, &.{ curve, .omitted, shifted }) });
    const instance = try runtime.objectValue(item, false);
    const command = (try instance.owner.scene.getNode(instance.index)).path;
    try std.testing.expectEqual(g.Transform.translation(5, 6), command.transform);
    try std.testing.expectEqualDeep(DisplayList.Pen{}, command.style.pen.?);
    try std.testing.expectError(error.TypeMismatch, runtime.invoke(a, .scale, &.{ .{ .int = 3 }, .unit }));
    for ([_]builtin.Id{ .dict_contains, .dict_remove, .dict_keys }) |id| try std.testing.expectError(error.InvalidBuiltin, runtime.invoke(a, id, &.{}));
}

test "list formatting preserves contents and marks cycles without exposing identity" {
    const a = std.testing.allocator;
    var identity: types.Ownership = .{};
    var cyclic: types.List.Owned = .{ .owner = &identity };
    defer cyclic.values.deinit(a);
    try cyclic.values.append(a, .{ .list = .{ .owned = &cyclic } });
    const rendered = try formatValue(a, .{ .list = .{ .owned = &cyclic } });
    defer a.free(rendered);
    try std.testing.expectEqualStrings("[[...]]", rendered);
    var view: [1]Value = undefined;
    view[0] = types.listView(&view);
    const borrowed = try formatValue(a, types.listView(&view));
    defer a.free(borrowed);
    try std.testing.expectEqualStrings(rendered, borrowed);
}

fn appendBytes(a: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8) FormatError!void {
    const limit = 8 * 1024 * 1024;
    if (bytes.len > limit - output.items.len) return error.ValueFormattingLimit;
    try output.appendSlice(a, bytes);
}

fn appendQuoted(a: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) FormatError!void {
    try appendBytes(a, output, "\"");
    var begin: usize = 0;
    for (text, 0..) |character, index| {
        const escaped: ?[]const u8 = switch (character) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escaped) |bytes| {
            try appendBytes(a, output, text[begin..index]);
            try appendBytes(a, output, bytes);
            begin = index + 1;
        }
    }
    try appendBytes(a, output, text[begin..]);
    try appendBytes(a, output, "\"");
}

fn appendValue(a: std.mem.Allocator, output: *std.ArrayList(u8), value: Value, depth: usize, remaining: *usize, ancestors: *[257]?SequenceIdentity) FormatError!void {
    if (depth > 256) return error.ValueNestingTooDeep;
    if (remaining.* == 0) return error.ValueFormattingLimit;
    remaining.* -= 1;
    var buffer: [4096]u8 = undefined;
    switch (value) {
        .list => |list| {
            const items = list.items();
            for (ancestors[0..depth]) |previous| if (previous) |identity| {
                if (identity.kind == .list and identity.address == @intFromPtr(items.ptr) and identity.len == items.len) return appendBytes(a, output, "[...]");
            };
            ancestors[depth] = .{ .address = @intFromPtr(items.ptr), .len = items.len };
            defer ancestors[depth] = null;
            try appendBytes(a, output, "[");
            for (items, 0..) |item, index| {
                if (index != 0) try appendBytes(a, output, ", ");
                try appendValue(a, output, item, depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, "]");
        },
        .dict => |dict| {
            for (ancestors[0..depth]) |previous| if (previous) |identity| {
                if (identity.kind == .dict and identity.address == @intFromPtr(dict)) return appendBytes(a, output, "{...}");
            };
            ancestors[depth] = .{ .address = @intFromPtr(dict), .kind = .dict };
            defer ancestors[depth] = null;
            try appendBytes(a, output, "{");
            for (dict.entries.keys(), dict.entries.values(), 0..) |key, item, index| {
                if (index != 0) try appendBytes(a, output, ", ");
                try appendQuoted(a, output, key);
                try appendBytes(a, output, ": ");
                try appendValue(a, output, item, depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, "}");
        },
        .record => |record_value| {
            for (ancestors[0..depth]) |previous| if (previous) |identity| {
                if (identity.kind == .record and identity.address == @intFromPtr(record_value)) return appendBytes(a, output, "struct{...}");
            };
            ancestors[depth] = .{ .address = @intFromPtr(record_value), .kind = .record };
            defer ancestors[depth] = null;
            try appendBytes(a, output, "struct{");
            for (record_value.fields, 0..) |item, index| {
                if (index != 0) try appendBytes(a, output, ", ");
                try appendValue(a, output, item, depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, "}");
        },
        .unit => try appendBytes(a, output, "()"),
        .omitted => return error.InvalidValue,
        .boolean => |x| try appendBytes(a, output, if (x) "true" else "false"),
        .string => |x| try appendBytes(a, output, x),
        .int => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "{d}", .{x}) catch return error.ValueFormattingLimit),
        .number => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "{d}", .{x}) catch return error.ValueFormattingLimit),
        .quantity => |x| {
            try appendBytes(a, output, std.fmt.bufPrint(&buffer, "{d}", .{x.value}) catch return error.ValueFormattingLimit);
            if (x.dimension.length != 0) {
                try appendBytes(a, output, "mm");
                if (x.dimension.length != 1) try appendBytes(a, output, std.fmt.bufPrint(&buffer, "^{d}", .{x.dimension.length}) catch return error.ValueFormattingLimit);
            }
            if (x.dimension.angle != 0) {
                if (x.dimension.length != 0) try appendBytes(a, output, " ");
                try appendBytes(a, output, "rad");
                if (x.dimension.angle != 1) try appendBytes(a, output, std.fmt.bufPrint(&buffer, "^{d}", .{x.dimension.angle}) catch return error.ValueFormattingLimit);
            }
        },
        inline .vec2, .vec3 => |x| {
            try appendBytes(a, output, "(");
            try appendValue(a, output, x.component(x.x), depth + 1, remaining, ancestors);
            try appendBytes(a, output, ", ");
            try appendValue(a, output, x.component(x.y), depth + 1, remaining, ancestors);
            if (@hasField(@TypeOf(x), "z")) {
                try appendBytes(a, output, ", ");
                try appendValue(a, output, x.component(x.z), depth + 1, remaining, ancestors);
            }
            try appendBytes(a, output, ")");
        },
        .function => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "<function:{s}:{d}>", .{ @tagName(x), switch (x) {
            .bytecode, .native => |i| i,
            .bound => |bound| switch (bound.target) {
                .bytecode, .native => |i| i,
            },
        } }) catch return error.ValueFormattingLimit),
        .object => try appendBytes(a, output, "<object>"),
        .handle => |x| try appendBytes(a, output, std.fmt.bufPrint(&buffer, "<{s}:{d}>", .{ x.kind.name(), x.index }) catch return error.ValueFormattingLimit),
    }
}

test "path queries keep source geometry and release native scratch and caller result graphs across OOM" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var outputs: std.heap.ArenaAllocator = .init(allocator);
            defer outputs.deinit();
            const out = outputs.allocator();
            var unused_library: typst.Library = undefined;
            var runtime = try Runtime.init(allocator, allocator, &unused_library, .{});
            defer runtime.deinit();
            const curve = try runtime.invoke(out, .bezier, &.{
                .{ .vec2 = .zero },
                .{ .vec2 = .{ .x = 0, .y = 2 } },
                .{ .vec2 = .{ .x = 2, .y = 2 } },
                .{ .vec2 = .{ .x = 2, .y = 0 } },
            });
            const original = try runtime.path(curve);
            const controls = original.segments.items[1].cubic;
            const closed = try runtime.invoke(out, .closed, &.{curve});
            const closed_path = try runtime.path(closed);
            try std.testing.expect(!closed_path.open and closed_path.segments.items.len == 3);
            try std.testing.expect(closed_path.segments.items.ptr != original.segments.items.ptr);
            const crossing = try runtime.invoke(out, .path, &.{
                .{ .vec2 = .{ .x = 1, .y = -1 } },
                .{ .vec2 = .{ .x = 1, .y = 2 } },
            });
            const times = try sequence(try runtime.invoke(out, .intersection_times, &.{ curve, crossing }));
            try std.testing.expectEqual(@as(usize, 1), times.len);
            try std.testing.expect(times[0].vec2.dimension.eql(.scalar));
            try std.testing.expectApproxEqAbs(@as(f64, 0.5), times[0].vec2.x, 1e-9);
            try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 6.0), times[0].vec2.y, 1e-9);

            const events = try sequence(try runtime.invoke(out, .path_crossings, &.{types.listView(&.{ curve, crossing })}));
            try std.testing.expectEqual(@as(usize, 1), events.len);
            const event = try sequence(events[0]);
            try std.testing.expectEqual(@as(usize, 7), event.len);
            try std.testing.expectEqual(@as(i64, 0), event[1].int);
            try std.testing.expectEqual(@as(i64, 0), event[2].int);
            try std.testing.expectEqual(@as(i64, 1), event[4].int);
            try std.testing.expectEqual(@as(i64, 0), event[5].int);
            try std.testing.expectApproxEqAbs(@as(f64, 0.5), event[3].number, 1e-9);
            try std.testing.expectApproxEqAbs(@as(f64, 5.0 / 6.0), event[6].number, 1e-9);

            const nib = try runtime.invoke(out, .pensquare, &.{});
            const ranges = types.listView(&.{types.listView(&.{ .{ .int = 0 }, .{ .number = 0 }, .{ .number = 0.5 } })});
            const sections = try sequence(try runtime.invoke(out, .stroke_sections, &.{ crossing, nib, ranges }));
            try std.testing.expectEqual(@as(usize, 1), sections.len);
            try std.testing.expect((try runtime.path(sections[0])).segmentCount() != 0);

            const by_length = try runtime.invoke(out, .sample_at_length, &.{ curve, .{ .number = 2 } });
            const by_fraction = try runtime.invoke(out, .sample_at_fraction, &.{ curve, .{ .number = 0.5 } });
            const batch = try sequence(try runtime.invoke(out, .samples_at_length, &.{ curve, types.listView(&.{ .{ .number = 0 }, .{ .number = 2 } }) }));
            try std.testing.expectEqual(@as(usize, 2), batch.len);
            for ([_]Value{ by_length, by_fraction, batch[1] }) |value| {
                const row = try sequence(value);
                try std.testing.expectEqual(@as(usize, 5), row.len);
                try std.testing.expectApproxEqAbs(@as(f64, 0.5), row[0].number, 1e-3);
                const position = try row[1].vec2.nativePoint();
                try std.testing.expectApproxEqAbs(@as(f64, 1), position.x, 1e-3);
                try std.testing.expectApproxEqAbs(@as(f64, 1.5), position.y, 1e-3);
                try std.testing.expect(row[2].vec2.dimension.eql(.scalar));
                try std.testing.expectApproxEqAbs(@as(f64, 1), row[2].vec2.x, 1e-3);
                try std.testing.expectApproxEqAbs(@as(f64, 0), row[2].vec2.y, 1e-3);
                try std.testing.expectApproxEqAbs(@as(f64, 0.5), row[3].number, 1e-3);
                try std.testing.expectEqual(@as(i64, 0), row[4].int);
            }
            const start = try sequence(batch[0]);
            try std.testing.expectEqual(@as(usize, 5), start.len);
            try std.testing.expectEqual(@as(f64, 0), start[0].number);
            try std.testing.expectEqualDeep(g.Point.zero, try start[1].vec2.nativePoint());
            try std.testing.expectEqual(@as(f64, 0), start[3].number);
            const unchanged = try runtime.path(curve);
            try std.testing.expect(unchanged.open and unchanged.segments.items.len == 2);
            try std.testing.expectEqualDeep(controls, unchanged.segments.items[1].cubic);
            try std.testing.expect(runtime.engine == null);
        }
    };
    try Check.run(std.testing.allocator);
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), Check.run, .{});
}

fn testOwner(value: Value) *SceneOwner {
    return @ptrCast(@alignCast(@constCast(value.object.owner)));
}
