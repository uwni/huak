//! C symbols and status values from libtypst's stable C API.
const std = @import("std");
pub const c = @import("typst_c");
pub const allocator = if (@import("builtin").single_threaded) std.heap.c_allocator else std.heap.smp_allocator;
pub const abi_version: u32 = c.TYPST_ABI_VERSION;
pub const required_capabilities: u64 = c.TYPST_CAP_PDF | c.TYPST_CAP_BATCH_LAYOUT |
    c.TYPST_CAP_NATIVE_SCENE | c.TYPST_CAP_TEXT_OUTLINE;

pub const Error = error{
    InvalidLibraryPath,
    LibraryNotFound,
    IncompatibleAbi,
    MissingSymbol,
    InvalidArgument,
    InvalidUtf8,
    CompileFailed,
    InvalidPage,
    TypstPanic,
    InvalidState,
    ExportFailed,
    Unsupported,
    InvalidResult,
    OutOfMemory,
};

/// Signatures come from the generated header rather than a second C API list.
pub const Functions = blk: {
    @setEvalBranchQuota(100_000);
    var count: usize = 0;
    for (@typeInfo(c).@"struct".decl_names) |name| {
        if (std.mem.startsWith(u8, name, "typst_") and @typeInfo(@TypeOf(@field(c, name))) == .@"fn") count += 1;
    }
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    const attrs: [count]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    var index: usize = 0;
    for (@typeInfo(c).@"struct".decl_names) |name| {
        if (std.mem.startsWith(u8, name, "typst_") and @typeInfo(@TypeOf(@field(c, name))) == .@"fn") {
            names[index] = name["typst_".len..];
            types[index] = *const @TypeOf(@field(c, name));
            index += 1;
        }
    }
    break :blk @Struct(.auto, null, &names, &types, &attrs);
};

pub fn compatible(version: u32, capabilities: u64) bool {
    return (version >> 16) == (abi_version >> 16) and
        (version & 0xffff) >= (abi_version & 0xffff) and
        (capabilities & required_capabilities) == required_capabilities;
}

pub fn load(dynamic: *std.DynLib) Error!Functions {
    const version_function = dynamic.lookup(*const @TypeOf(c.typst_abi_version), "typst_abi_version") orelse return error.MissingSymbol;
    const version = version_function();
    if ((version >> 16) != (abi_version >> 16) or (version & 0xffff) < (abi_version & 0xffff)) return error.IncompatibleAbi;
    const information = dynamic.lookup(*const @TypeOf(c.typst_version_info), "typst_version_info") orelse return error.MissingSymbol;
    var info: c.TypstVersionInfo = undefined;
    if (information(&info) != c.TYPST_OK or !compatible(version, info.capabilities) or
        info.abi_major != (version >> 16) or info.abi_minor != (version & 0xffff)) return error.IncompatibleAbi;
    var functions: Functions = undefined;
    inline for (@typeInfo(Functions).@"struct".field_names) |name| {
        @field(functions, name) = dynamic.lookup(@FieldType(Functions, name), "typst_" ++ name) orelse return error.MissingSymbol;
    }
    return functions;
}

pub fn str(value: []const u8) c.TypstStr {
    return .{ .data = value.ptr, .len = value.len };
}
pub fn binary(value: []const u8) c.TypstBytes {
    return .{ .data = value.ptr, .len = value.len };
}
pub fn bytes(value: anytype) []const u8 {
    return if (value.len == 0) &.{} else value.data[0..value.len];
}
pub fn status(value: c.TypstStatus) Error!void {
    return switch (value) {
        c.TYPST_OK => {},
        c.TYPST_INVALID_ARGUMENT => error.InvalidArgument,
        c.TYPST_INVALID_UTF8 => error.InvalidUtf8,
        c.TYPST_COMPILE_FAILED => error.CompileFailed,
        c.TYPST_UNSUPPORTED => error.Unsupported,
        c.TYPST_PANIC => error.TypstPanic,
        c.TYPST_OUT_OF_RANGE => error.InvalidPage,
        else => error.InvalidResult,
    };
}
