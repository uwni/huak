//! Final handoff from mutable language state to independent output jobs.
//! Pictures move without copying geometry. Shared layouts survive until their
//! last selected picture finishes; no VM, Program or engine is borrowed.
const std = @import("std");
const typst = @import("libtypst");
const Scene = @import("../drawing/Scene.zig");
const objects = @import("runtime/objects.zig");
const renderer = @import("../render/root.zig");

/// Every reachable Scene must belong to an objects.Owner. Standalone geometry
/// scenes are not language output sources; their storage has a different owner.
pub const Source = Scene.Object;

const Layout = Shared(typst.Layout);
const Geometry = Shared(objects.Storage);

fn Shared(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        value: T = undefined,
        references: std.atomic.Value(usize) = .init(0),

        fn release(self: *@This()) void {
            if (self.references.fetchSub(1, .acq_rel) != 1) return;
            self.value.deinit();
            self.allocator.destroy(self);
        }
    };
}

const Target = struct {
    allocator: std.mem.Allocator,
    view: objects.View,
    has_mesh: bool = false,
    /// Each reference retains its enclosing shared Layout exactly once.
    frames: []typst.FrameRef = &.{},
    geometry: []*Geometry = &.{},
    references: std.atomic.Value(usize) = .init(1),

    fn scene(self: *const Target) !renderer.Scene {
        return .{
            .picture = &self.view.snapshot.picture,
            .size = self.view.settings.size,
            .frames = self.frames,
            .tracks = try self.view.animation(),
            .object_ids = if (self.view.tracks.items.len != 0) self.view.snapshot.ids.items else null,
        };
    }

    fn release(self: *Target) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        for (self.frames) |frame| {
            const layout: *Layout = @fieldParentPtr("value", @constCast(frame.layout));
            layout.release();
        }
        for (self.geometry) |owner| owner.release();
        self.destroy();
    }

    fn destroy(self: *Target) void {
        self.view.deinit();
        self.allocator.free(self.frames);
        self.allocator.free(self.geometry);
        self.allocator.destroy(self);
    }
};

const OutputBatch = @This();

allocator: std.mem.Allocator,
/// Borrowed at a stable address, through Batch and returned Buffer lifetimes.
library: *typst.Library,
entries: []?*Target,

/// Consumes selected picture/state owners and referenced Layout handles on
/// success; leaves all source owners intact on failure. Sources may repeat.
/// Label references are compacted per picture. The allocator, including the
/// original pictures' allocators, must support concurrent frees when jobs
/// execute concurrently. Call release exactly once per job, after render.
pub fn init(allocator: std.mem.Allocator, library: *typst.Library, sources: []const Source, frames: []const typst.FrameRef) !OutputBatch {
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    // Containers stay fixed throughout this read-only preparation. Their
    // settings addresses identify nodes even when several share a Scene.
    var targets: std.AutoHashMapUnmanaged(*const Scene.Settings, *Target) = .empty;
    var layouts: std.AutoHashMapUnmanaged(*const typst.Layout, *Layout) = .empty;
    var geometry: std.AutoHashMapUnmanaged(*const Scene, *Geometry) = .empty;
    const entries = try allocator.alloc(?*Target, sources.len);
    @memset(entries, null);
    errdefer allocator.free(entries);
    errdefer {
        var target_values = targets.valueIterator();
        while (target_values.next()) |target| target.*.destroy();
        var layout_values = layouts.valueIterator();
        while (layout_values.next()) |layout| allocator.destroy(layout.*);
        var geometry_values = geometry.valueIterator();
        while (geometry_values.next()) |owner| allocator.destroy(owner.*);
    }
    for (sources, entries) |source, *entry| {
        const container = try source.scene.settings(source.index);
        if (targets.get(container)) |target| {
            _ = target.references.fetchAdd(1, .monotonic);
            entry.* = target;
            continue;
        }
        const target = target: {
            var view = try objects.Owner.fromScene(source.scene).viewWithBounds(allocator, source.index, renderer.FrameBounds{ .frames = frames });
            errdefer view.deinit();
            if (try view.animation()) |animation| try animation.validate();
            try targets.ensureUnusedCapacity(scratch, 1);
            const result = try allocator.create(Target);
            result.* = .{ .allocator = allocator, .view = view };
            // Registration transfers cleanup to the batch transaction.
            targets.putAssumeCapacityNoClobber(container, result);
            break :target result;
        };
        entry.* = target;
        const snapshot = &target.view.snapshot;
        target.geometry = try allocator.alloc(*Geometry, snapshot.owners.count());
        for (snapshot.owners.keys(), target.geometry) |storage, *retained| {
            const owner = geometry.get(storage) orelse owner: {
                try geometry.ensureUnusedCapacity(scratch, 1);
                const result = try allocator.create(Geometry);
                result.* = .{ .allocator = allocator };
                geometry.putAssumeCapacityNoClobber(storage, result);
                break :owner result;
            };
            _ = owner.references.fetchAdd(1, .monotonic);
            retained.* = owner;
        }
        // The registry only guides handoff. Jobs retain storage through
        // geometry references, never pointers to the mutable source scenes.
        snapshot.owners.clearAndFree(allocator);
        var references: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (snapshot.picture.commands.items) |*command| {
            if (renderer.usesMesh(command)) target.has_mesh = true;
            if (command.* != .label) continue;
            const reference = command.label.reference;
            if (reference >= frames.len) return error.InvalidFrameReference;
            const mapped = try references.getOrPut(scratch, reference);
            if (!mapped.found_existing) mapped.value_ptr.* = references.count() - 1;
            // Snapshot commands are owned here; source scenes remain
            // untouched until the ownership commit below.
            command.label.reference = mapped.value_ptr.*;
        }
        target.frames = try allocator.alloc(typst.FrameRef, references.count());
        var referenced_frames = references.iterator();
        while (referenced_frames.next()) |reference| {
            const index = reference.value_ptr.*;
            const frame = frames[reference.key_ptr.*];
            const owner = layouts.get(frame.layout) orelse owner: {
                try layouts.ensureUnusedCapacity(scratch, 1);
                const result = try allocator.create(Layout);
                result.* = .{ .allocator = allocator, .value = .{ .library = library, .handle = null } };
                layouts.putAssumeCapacityNoClobber(frame.layout, result);
                break :owner result;
            };
            _ = owner.references.fetchAdd(1, .monotonic);
            target.frames[index] = .{ .layout = &owner.value, .index = frame.index };
        }
    }
    // No allocations or other failures after this ownership commit.
    var layout_moves = layouts.iterator();
    while (layout_moves.next()) |move| {
        move.value_ptr.*.value = move.key_ptr.*.*;
        @constCast(move.key_ptr.*).handle = null;
    }
    var geometry_moves = geometry.iterator();
    while (geometry_moves.next()) |move| move.value_ptr.*.value = objects.Owner.fromScene(move.key_ptr.*).takeStorage();
    return .{ .allocator = allocator, .library = library, .entries = entries };
}

pub fn len(self: *const OutputBatch) usize {
    return self.entries.len;
}

pub fn validate(self: *const OutputBatch, index: usize, format: renderer.Format) !void {
    const target = self.entries[index] orelse return error.ReleasedOutput;
    try format.validate((try target.view.animation()) != null, target.has_mesh);
}

pub fn render(self: *const OutputBatch, allocator: std.mem.Allocator, index: usize, format: renderer.Format, diagnostic: *?typst.Buffer) !renderer.Output {
    const target = self.entries[index] orelse return error.ReleasedOutput;
    return (try target.scene()).render(allocator, self.library, format, diagnostic);
}

/// Different indices may be released concurrently. The same index must not
/// be accessed again; aliases keep their shared target alive independently.
pub fn release(self: *OutputBatch, index: usize) void {
    const target = self.entries[index] orelse return;
    self.entries[index] = null;
    target.release();
}

/// All render/release calls must finish first. Also frees unstarted jobs.
pub fn deinit(self: *OutputBatch) void {
    for (0..self.entries.len) |index| self.release(index);
    self.allocator.free(self.entries);
    self.* = undefined;
}
