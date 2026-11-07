//! POSIX desktop loader. Resolve dependencies at open time so an optional
//! backend with a missing function cannot abort the process on its first call.
const std = @import("std");
const dl = @import("dlfcn");
const SharedLibrary = @This();

handle: *anyopaque,

pub fn open(path: []const u8) error{ InvalidLibraryPath, LibraryNotFound }!SharedLibrary {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidLibraryPath;
    const name = std.posix.toPosixPath(path) catch return error.InvalidLibraryPath;
    return .{ .handle = @call(.never_tail, dl.dlopen, .{ &name, dl.RTLD_NOW | dl.RTLD_LOCAL }) orelse return error.LibraryNotFound };
}

pub fn lookup(self: *const SharedLibrary, comptime T: type, name: [:0]const u8) ?T {
    const symbol = @call(.never_tail, std.c.dlsym, .{ self.handle, name.ptr }) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

/// The loader owns the pathname for the lifetime of its image.
pub fn imagePath(symbol: *const anyopaque) ?[:0]const u8 {
    var info: dl.Dl_info = undefined;
    if (dl.dladdr(symbol, &info) == 0 or info.dli_fname == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(info.dli_fname)));
}

pub fn close(self: *SharedLibrary) void {
    const status = std.c.dlclose(self.handle);
    std.debug.assert(status == 0);
    self.* = undefined;
}
