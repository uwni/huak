//! Per-execution owners for existing geometry, pictures and native text frames.
//! The VM sees typed indices. Typst and geometry owners never cross the DSL API.
const std = @import("std");
const typst = @import("libtypst");
const Path = @import("../drawing/path/Path.zig");
const Measure = @import("../drawing/path/Measure.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const constraints = @import("../drawing/solver.zig");
const outline = @import("../text/outline.zig");
const Machine = @import("Machine.zig");
const types = @import("types.zig");
const renderer = @import("../render/root.zig");
const Workers = @import("workers");
const OutputBatch = @import("OutputBatch.zig");
const task_owners = @import("runtime/tasks.zig");
const Value = types.Value;
const typesetting = @import("runtime/typesetting.zig");
const object_handles = @import("runtime/object_handles.zig");
const conversions = @import("runtime/conversions.zig");
const outlines = @import("runtime/outlines.zig");
pub const formatting = @import("runtime/formatting.zig");
const solver = @import("runtime/solver.zig");
const typeset_text = @import("runtime/typeset_text.zig");
const builtin_calls = @import("runtime/builtin_calls.zig");
const fields = @import("runtime/fields.zig");
const formatValue = formatting.formatValue;
const Transform = @import("runtime/transforms.zig").Transform;
const Variable = solver.Variable;
const Expr = solver.Expr;
const Solved = solver.Solved;
const Text = typeset_text.Text;
const Anchor = typeset_text.Anchor;
const TypstModule = typesetting.TypstModule;
const copyOptions = typesetting.copyOptions;
const releaseLayout = typesetting.releaseLayout;
const releaseText = typeset_text.releaseText;
const freeOptions = typesetting.freeOptions;
const call = builtin_calls.call;
const field = fields.field;
const binary = solver.binary;
const typeset = typesetting.typeset;
const typesetBatch = typesetting.typesetBatch;
const makeTypstModule = typesetting.makeTypstModule;
const checkedIndex = conversions.checkedIndex;
pub const SceneOwner = @import("runtime/objects.zig").Owner;
pub const Format = renderer.Format;
pub const Output = renderer.Output;
/// Host-owned services. Every worker borrows the same backends until it joins.
pub const Backends = struct {
    typst: *typst.Library,
    projection: ?*const @import("../drawing/space/Projection.zig").VTable = null,
    /// Scene storages attached to one store share mesh arrays. Like the
    /// library, it stays at a stable address until this Runtime and every
    /// exported result are freed. Without a store each picture copies meshes.
    meshes: ?*DisplayList.MeshStore = null,
    /// Bounded concurrency budget shared by automatic construction tasks and
    /// data-parallel host operations such as transparency flattening.
    workers: Workers = .serial,
};
pub const Options = struct {
    /// Configuration bytes are copied during Runtime.init. Library is borrowed
    /// at a stable address until Runtime and every exported result are freed.
    font_sources: []const typst.FontSource = &.{},
    /// Font directories and system fonts are discovered by libtypst.
    font_dirs: []const []const u8 = &.{},
    system_fonts: bool = false,
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

pub const TaskCheckpoint = task_owners.Checkpoint;
/// Owns every registry and every value they hold. Values are released with
/// the runtime; geometry operations get this allocator for their results and
/// return their working memory to it as they go.
gpa: std.mem.Allocator,
/// Scene arrays and paints retain this allocator through output handoff.
scene_allocator: std.mem.Allocator,
backends: Backends,
/// Copies owned by the root runtime; task children borrow them.
options: Options,
outputs_taken: bool = false,
engine: ?typst.Engine = null,
/// Task children borrow a stable engine and immutable input owners until
/// their task group joins. Their metadata remains independent.
shared_engine: ?*typst.Engine = null,
task_borrow: ?task_owners.Borrowed = null,
printed: std.ArrayList(u8) = .empty,
/// The latest native diagnostic: a static string or text in `message`.
native_message: []const u8 = "",
message: std.ArrayList(u8) = .empty,
path_values: std.ArrayList(Path) = .empty,
measures: std.ArrayList(Measure) = .empty,
colors: std.ArrayList(DisplayList.Color) = .empty,
pens: std.ArrayList(DisplayList.Pen) = .empty,
/// Individually allocated with their own arrays: pens point at them.
gradients: std.ArrayList(*DisplayList.Gradient) = .empty,
transforms: std.ArrayList(Transform) = .empty,
models: std.ArrayList(Model.Node) = .empty,
solvers: std.ArrayList(*constraints.Solver) = .empty,
variables: std.ArrayList(Variable) = .empty,
expressions: std.ArrayList(Expr) = .empty,
solutions: std.ArrayList(Solved) = .empty,
texts: std.ArrayList(Text) = .empty,
anchors: std.ArrayList(Anchor) = .empty,
/// Individually allocated: an evaluated module refers to the modules it was
/// made with, so their addresses stay fixed as the list grows.
typst_modules: std.ArrayList(*TypstModule) = .empty,
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
    return .{ .gpa = allocator, .scene_allocator = scene_allocator, .backends = backends, .options = try copyOptions(allocator, options) };
}

/// The first entry of a registry that this runtime owns. A task child shares
/// the entries before it with its parent.
pub fn firstOwned(self: *const Runtime, comptime registry: []const u8) usize {
    return if (self.task_borrow) |borrowed| @field(borrowed.lengths, registry) else 0;
}

/// The entries of a registry that this runtime owns. A fork that failed
/// part-way may hold fewer entries than it borrowed, and owns none.
fn owned(self: *Runtime, comptime registry: []const u8) @FieldType(@FieldType(Runtime, registry), "items") {
    const items = @field(self, registry).items;
    return items[@min(self.firstOwned(registry), items.len)..];
}

pub fn deinit(self: *Runtime) void {
    const gpa = self.gpa;
    for (self.owned("measures")) |*measure| measure.deinit();
    var cached_outlines = self.outline_cache.valueIterator();
    while (cached_outlines.next()) |batch| batch.deinit();
    self.outline_cache.deinit(gpa);
    for (self.owned("layouts")) |layout| releaseLayout(gpa, layout);
    for (self.owned("typst_modules")) |module| {
        module.release(gpa);
        gpa.destroy(module);
    }
    if (self.engine) |*engine| engine.deinit();
    const adopted = if (self.task_borrow) |*borrowed| if (borrowed.adopted) |*owners| owners else null else null;
    for (self.owned("scene_values")) |target| {
        if (adopted) |owners| if (owners.contains(&target.scene)) continue;
        target.scene.deinit();
        target.animation_state.deinit();
        gpa.destroy(target);
    }
    if (adopted) |owners| owners.deinit(gpa);
    for (self.owned("path_values")) |*value| value.deinit();
    for (self.owned("pens")) |*value| value.freeData(gpa);
    for (self.owned("gradients")) |value| {
        value.deinit(gpa);
        gpa.destroy(value);
    }
    for (self.owned("transforms")) |value| if (value == .spatial) gpa.destroy(value.spatial);
    for (self.owned("models")) |value| gpa.free(value.arguments);
    for (self.owned("solvers")) |value| {
        value.deinit();
        gpa.destroy(value);
    }
    for (self.owned("expressions")) |value| gpa.free(value.expression.terms);
    for (self.owned("solutions")) |*value| value.solution.deinit();
    // A child forks with no cached anchors, so every cached dictionary
    // belongs to the runtime whose text entry holds it.
    for (self.texts.items) |*text| releaseText(gpa, text);
    inline for (@typeInfo(task_owners.Lengths).@"struct".field_names) |name| @field(self, name).deinit(gpa);
    self.printed.deinit(gpa);
    self.message.deinit(gpa);
    if (self.task_borrow == null) freeOptions(gpa, self.options);
    self.* = undefined;
}

const host_vtable: Machine.Host.VTable = .{ .callBuiltin = call, .field = field, .binary = binary, .typst = typeset, .typstBatch = typesetBatch, .typstModule = makeTypstModule, .errorMessage = diagnostic };
const single_host_vtable = blk: {
    var table = host_vtable;
    table.typstBatch = null;
    break :blk table;
};

pub fn host(self: *Runtime) Machine.Host {
    return .{ .ptr = self, .vtable = if (self.task_borrow == null) &host_vtable else &single_host_vtable };
}

/// Called by the coordinator before any children borrow this runtime.
/// The engine, options and input owners must outlive the joined group.
pub fn prepareTasks(self: *Runtime, needs_typst: bool) !void {
    if (self.outputs_taken or self.task_borrow != null) return error.InvalidState;
    if (needs_typst) _ = try typesetting.engineRef(self);
}

/// Snapshot metadata on the coordinator; run the returned runtime on one
/// worker only. The root allocator must support concurrent allocation.
pub fn forkTask(self: *Runtime, child_workers: Workers) !Runtime {
    return task_owners.fork(self, child_workers);
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
    const target = try object_handles.objectValue(self, value, false);
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
        .svg_mesh = selected.settings.svg_mesh,
        .workers = self.backends.workers,
    };
    var diagnostic_buffer: ?typst.Buffer = null;
    defer if (diagnostic_buffer) |*buffer| buffer.deinit();
    return scene.render(self.gpa, self.backends.typst, format, &diagnostic_buffer) catch |err| {
        if (diagnostic_buffer) |buffer| self.setMessage(buffer.bytes());
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
        const target = try object_handles.objectValue(self, value, false);
        source.* = target.owner.scene.object(target.index);
    }
    const batch = try OutputBatch.init(self.gpa, self.backends.typst, sources, self.frames.items);
    self.outputs_taken = true;
    return batch;
}
/// Keeps a copy of a native diagnostic until the next one replaces it.
/// `text` must not point into the previous message.
pub fn setMessage(self: *Runtime, text: []const u8) void {
    self.message.clearRetainingCapacity();
    self.message.appendSlice(self.gpa, text) catch {
        self.native_message = "cannot copy native diagnostic";
        return;
    };
    self.native_message = self.message.items;
}
pub fn setMessageFormat(self: *Runtime, comptime format: []const u8, args: anytype) void {
    self.message.clearRetainingCapacity();
    self.message.print(self.gpa, format, args) catch {
        self.native_message = "cannot copy native diagnostic";
        return;
    };
    self.native_message = self.message.items;
}
pub fn from(ctx: ?*anyopaque) *Runtime {
    return @ptrCast(@alignCast(ctx.?));
}
fn diagnostic(ctx: ?*anyopaque) []const u8 {
    return from(ctx).native_message;
}

pub fn path(self: *Runtime, value: Value) !Path {
    return self.path_values.items[try checkedIndex(value, .path, self.path_values.items.len)];
}
pub fn affineValue(self: *Runtime, value: Value) !Transform {
    return self.transforms.items[try checkedIndex(value, .transform, self.transforms.items.len)];
}
pub fn model(self: *Runtime, value: Value) !Model.Node {
    return self.models.items[try checkedIndex(value, .shape, self.models.items.len)];
}
/// Takes ownership of `value`, also when storing it fails.
pub fn pathResult(self: *Runtime, value: Path) !Value {
    var result = value;
    errdefer result.deinit();
    return conversions.store(self, Path, &self.path_values, result, .path);
}
pub fn resolveOutline(self: *Runtime, allocator: std.mem.Allocator, reference: u32) !DisplayList {
    const label = try outlines.outlinedLabel(self, reference);
    var result = DisplayList.init(allocator);
    errdefer result.deinit();
    // Cached editable glyphs are baseline-relative and y-up. DisplayList's
    // label transform expects original frame-local y-down coordinates.
    try label.addToPicture(&result, .{ .d = -1, .f = label.metrics.baseline });
    return result;
}
pub fn animationPath(self: *Runtime, value: Value) ![]const Path.Segment {
    return (try self.path(value)).segments.items;
}

pub fn animationColor(self: *Runtime, value: Value) !DisplayList.Color {
    return conversions.color(self, value);
}

test {
    _ = @import("runtime/conversions.zig");
    _ = @import("runtime/formatting.zig");
    _ = @import("runtime/pen.zig");
    _ = @import("runtime/paths_test.zig");
    _ = @import("runtime/path_queries.zig");
    _ = @import("runtime/regions.zig");
    _ = @import("runtime/outlines.zig");
    _ = @import("runtime/pictures_test.zig");
    _ = @import("runtime/animation.zig");
}
