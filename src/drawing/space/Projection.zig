//! Owns the desktop projection library. Runtimes borrow its read-only function
//! table. All calls and result releases must finish before close.
const SharedLibrary = @import("shared_library");
const c = @import("space_c");
const Projection = @This();

pub const VTable = c.HuakProjectionV1;
library: SharedLibrary,
path: [:0]const u8,
vtable: *const VTable,

pub fn open(path: []const u8) !Projection {
    var library = try SharedLibrary.open(path);
    errdefer library.close();
    const get = library.lookup(@TypeOf(&c.huak_space_api_v1), "huak_space_api_v1") orelse return error.IncompatibleProjection;
    const table: ?*const VTable = get();
    const vtable = table orelse return error.IncompatibleProjection;
    if (vtable.project == null or vtable.release == null) return error.IncompatibleProjection;
    return .{ .library = library, .vtable = vtable, .path = SharedLibrary.imagePath(get) orelse return error.IncompatibleProjection };
}

pub fn close(self: *Projection) void {
    self.library.close();
    self.* = undefined;
}

/// The Playground owns the linked backend for the lifetime of its Wasm instance.
pub fn linked() *const VTable {
    return c.huak_space_api_v1();
}
