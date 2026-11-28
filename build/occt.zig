//! Builds the OCCT 8.0.x modeling toolkits statically from the `occt` package in `build.zig.zon`.
const std = @import("std");
const LazyPath = std.Build.LazyPath;

/// The OCCT modeling toolkits needed by `src/drawing/space/`, in dependency
/// closure of `TKOffset` and `TKHLR`.
const toolkits = [_][]const u8{
    "FoundationClasses/TKernel",
    "FoundationClasses/TKMath",
    "ModelingData/TKG2d",
    "ModelingData/TKG3d",
    "ModelingData/TKGeomBase",
    "ModelingData/TKBRep",
    "ModelingAlgorithms/TKGeomAlgo",
    "ModelingAlgorithms/TKTopAlgo",
    "ModelingAlgorithms/TKPrim",
    "ModelingAlgorithms/TKBO",
    "ModelingAlgorithms/TKShHealing",
    "ModelingAlgorithms/TKBool",
    "ModelingAlgorithms/TKFillet",
    "ModelingAlgorithms/TKHLR",
    "ModelingAlgorithms/TKOffset",
};

pub const Library = struct {
    archive: *std.Build.Step.Compile,
    include_paths: []const LazyPath,

    pub fn linkInto(self: Library, mod: *std.Build.Module) void {
        for (self.include_paths) |path| mod.addSystemIncludePath(path);
        mod.linkLibrary(self.archive);
    }
};

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) Library {
    const dep = b.dependency("occt", .{});
    const arena = b.graph.arena;
    const io = b.graph.io;
    const root_handle = dep.builder.root.root_dir.handle;
    const prefix = sourcePrefix(b, root_handle);
    const root_sub = std.mem.trimEnd(u8, prefix, "/");
    const root_path = dep.path(root_sub);

    const version_cmake = readText(io, arena, root_handle, b.fmt("{s}adm/cmake/version.cmake", .{prefix}));
    const generated = b.addWriteFiles();
    _ = generated.add("Standard_Version.hxx", renderVersionHeader(b, version_cmake));

    var include_paths: std.ArrayList(LazyPath) = .empty;
    include_paths.append(arena, generated.getDirectory()) catch @panic("OOM");

    var cxx_files: std.ArrayList([]const u8) = .empty;
    var c_files: std.ArrayList([]const u8) = .empty;

    for (toolkits) |toolkit| {
        const toolkit_name = std.Io.Dir.path.basename(toolkit);
        const packages_text = readText(
            io,
            arena,
            root_handle,
            b.fmt("{s}src/{s}/PACKAGES.cmake", .{ prefix, toolkit }),
        );
        const packages_var = b.fmt("OCCT_{s}_LIST_OF_PACKAGES", .{toolkit_name});
        const packages = parseCmakeList(arena, packages_text, packages_var);

        for (packages) |package| {
            const pkg_rel = b.fmt("src/{s}/{s}", .{ toolkit, package });
            include_paths.append(arena, root_path.path(b, pkg_rel)) catch @panic("OOM");

            const files_text = readText(
                io,
                arena,
                root_handle,
                b.fmt("{s}{s}/FILES.cmake", .{ prefix, pkg_rel }),
            );
            const files_var = b.fmt("OCCT_{s}_FILES", .{package});
            const entries = parseCmakeList(arena, files_text, files_var);

            for (entries) |entry| {
                if (std.mem.endsWith(u8, entry, ".cxx") or std.mem.endsWith(u8, entry, ".cpp")) {
                    cxx_files.append(arena, b.fmt("{s}/{s}", .{ pkg_rel, entry })) catch @panic("OOM");
                } else if (std.mem.endsWith(u8, entry, ".c")) {
                    c_files.append(arena, b.fmt("{s}/{s}", .{ pkg_rel, entry })) catch @panic("OOM");
                }
            }
        }
    }

    // Keep OCCT optimized and stripped of DWARF debug info (matching upstream
    // Release builds) so 3D tests stay fast, caches stay small, and Linux
    // shared libraries do not embed ~160 MB of OCCT debug sections.
    const occt_optimize: std.lang.Optimize = if (optimize == .small) .small else .fast;
    const mod = b.createModule(.{
        .target = target,
        .optimize = occt_optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
        .strip = true,
        .sanitize_c = .off,
    });
    for (include_paths.items) |path| mod.addSystemIncludePath(path);

    var cxx_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(arena, &.{
        "-std=c++17",
        "-fexceptions",
        "-frtti",
        "-fno-strict-aliasing",
        "-fno-sanitize=undefined",
        "-fvisibility=hidden",
        "-fvisibility-inlines-hidden",
        "-ffunction-sections",
        "-fdata-sections",
        "-DOCC_CONVERT_SIGNALS",
        "-DOCCT_STATIC_BUILD",
        "-DNo_Exception",
        "-Wno-deprecated-declarations",
    }) catch @panic("OOM");
    if (target.result.os.tag == .macos) {
        cxx_flags.append(arena, "-Wno-elaborated-enum-base") catch @panic("OOM");
    }

    const c_flags = [_][]const u8{
        "-fexceptions",
        "-fno-strict-aliasing",
        "-fno-sanitize=undefined",
        "-fvisibility=hidden",
        "-ffunction-sections",
        "-fdata-sections",
        "-DOCC_CONVERT_SIGNALS",
        "-DOCCT_STATIC_BUILD",
        "-DNo_Exception",
    };

    mod.addCSourceFiles(.{
        .root = root_path,
        .files = cxx_files.items,
        .flags = cxx_flags.items,
    });
    if (c_files.items.len > 0) {
        mod.addCSourceFiles(.{
            .root = root_path,
            .files = c_files.items,
            .flags = &c_flags,
        });
    }

    const archive = b.addLibrary(.{
        .name = "occt",
        .linkage = .static,
        .root_module = mod,
    });
    return .{
        .archive = archive,
        .include_paths = include_paths.items,
    };
}

fn sourcePrefix(b: *std.Build, root: std.Io.Dir) []const u8 {
    const io = b.graph.io;
    if (root.openDir(io, "src", .{})) |dir| {
        var open = dir;
        open.close(io);
        return "";
    } else |_| {}

    var iter_dir = root.openDir(io, ".", .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open OCCT package root: {t}", .{err});
    defer iter_dir.close(io);

    var iterator = iter_dir.iterate();
    while (iterator.next(io) catch |err|
        std.debug.panic("cannot iterate OCCT package root: {t}", .{err})) |entry|
    {
        if (entry.kind != .directory) continue;
        const candidate = b.fmt("{s}/src", .{entry.name});
        if (root.openDir(io, candidate, .{})) |dir| {
            var open = dir;
            open.close(io);
            return b.fmt("{s}/", .{entry.name});
        } else |_| {}
    }
    @panic("OCCT dependency does not contain a src/ directory");
}

fn readText(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) []const u8 {
    return dir.readFileAlloc(io, sub_path, allocator, .unlimited) catch |err|
        std.debug.panic("failed to read OCCT file '{s}': {t}", .{ sub_path, err });
}

fn renderVersionHeader(b: *std.Build, version_cmake: []const u8) []const u8 {
    const arena = b.graph.arena;
    const major = parseSingleValue(arena, version_cmake, "OCC_VERSION_MAJOR");
    const minor = parseSingleValue(arena, version_cmake, "OCC_VERSION_MINOR");
    const maintenance = parseSingleValue(arena, version_cmake, "OCC_VERSION_MAINTENANCE");
    return b.fmt(
        \\#ifndef _Standard_Version_HeaderFile
        \\#define _Standard_Version_HeaderFile
        \\
        \\#define OCC_VERSION_MAJOR {s}
        \\#define OCC_VERSION_MINOR {s}
        \\#define OCC_VERSION_MAINTENANCE {s}
        \\
        \\#define OCC_VERSION {s}.{s}
        \\#define OCC_VERSION_STRING "{s}.{s}"
        \\#define OCC_VERSION_COMPLETE "{s}.{s}.{s}"
        \\
        \\#ifdef OCC_VERSION_DEVELOPMENT
        \\  #define OCC_VERSION_STRING_EXT OCC_VERSION_COMPLETE "." OCC_VERSION_DEVELOPMENT
        \\#else
        \\  #define OCC_VERSION_STRING_EXT OCC_VERSION_COMPLETE
        \\#endif
        \\
        \\#define OCC_VERSION_HEX (OCC_VERSION_MAJOR << 16 | OCC_VERSION_MINOR << 8 | OCC_VERSION_MAINTENANCE)
        \\
        \\#endif
        \\
    , .{ major, minor, maintenance, major, minor, major, minor, major, minor, maintenance });
}

fn parseSingleValue(allocator: std.mem.Allocator, content: []const u8, var_name: []const u8) []const u8 {
    const values = parseCmakeList(allocator, content, var_name);
    if (values.len != 1) std.debug.panic("expected single value for CMake variable '{s}'", .{var_name});
    return values[0];
}

fn parseCmakeList(allocator: std.mem.Allocator, content: []const u8, var_name: []const u8) []const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.findScalar(u8, raw_line, '#')) |hash| raw_line[0..hash] else raw_line;
        var i: usize = 0;
        while (i < line.len) {
            while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
            if (i >= line.len) break;
            if (line[i] == '(' or line[i] == ')') {
                tokens.append(allocator, line[i .. i + 1]) catch @panic("OOM");
                i += 1;
                continue;
            }
            const start = i;
            while (i < line.len and !std.ascii.isWhitespace(line[i]) and line[i] != '(' and line[i] != ')') : (i += 1) {}
            tokens.append(allocator, line[start..i]) catch @panic("OOM");
        }
    }

    var idx: usize = 0;
    while (idx + 2 < tokens.items.len) : (idx += 1) {
        if (!std.ascii.eqlIgnoreCase(tokens.items[idx], "set")) continue;
        if (!std.mem.eql(u8, tokens.items[idx + 1], "(")) continue;
        if (!std.mem.eql(u8, tokens.items[idx + 2], var_name)) continue;

        var values: std.ArrayList([]const u8) = .empty;
        var cursor = idx + 3;
        while (cursor < tokens.items.len and !std.mem.eql(u8, tokens.items[cursor], ")")) : (cursor += 1) {
            values.append(allocator, tokens.items[cursor]) catch @panic("OOM");
        }
        return values.items;
    }
    std.debug.panic("CMake variable '{s}' not found", .{var_name});
}
