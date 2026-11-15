//! Owns the desktop projection library. Runtimes borrow its read-only function
//! table. All calls and result releases must finish before close.
const SharedLibrary = @import("shared_library");
const c = @import("space_c");
const Projection = @This();

pub const VTable = c.HuakProjectionV3;
pub const Model = @import("Model.zig");
pub const linework = @import("linework.zig");
library: SharedLibrary,
path: [:0]const u8,
vtable: *const VTable,

pub fn open(path: []const u8) !Projection {
    var library = try SharedLibrary.open(path);
    errdefer library.close();
    const get = library.lookup(@TypeOf(&c.huak_space_api_v3), "huak_space_api_v3") orelse return error.IncompatibleProjection;
    const table: ?*const VTable = get();
    const vtable = table orelse return error.IncompatibleProjection;
    try check(vtable);
    return .{ .library = library, .vtable = vtable, .path = SharedLibrary.imagePath(get) orelse return error.IncompatibleProjection };
}

pub fn close(self: *Projection) void {
    self.library.close();
    self.* = undefined;
}

/// The Playground owns the linked backend for the lifetime of its Wasm instance.
pub fn linked() *const VTable {
    return c.huak_space_api_v3();
}

/// A table this host can use: the same major version, at least the entries
/// this host knows, and none of them missing.
fn check(vtable: *const VTable) error{IncompatibleProjection}!void {
    if (vtable.abi_version >> 16 != c.HUAK_SPACE_ABI_VERSION >> 16 or vtable.size < @sizeOf(VTable)) return error.IncompatibleProjection;
    inline for (@typeInfo(VTable).@"struct".field_names) |name| {
        if (@typeInfo(@TypeOf(@field(vtable, name))) == .optional and @field(vtable, name) == null) return error.IncompatibleProjection;
    }
}
