const std = @import("std");
const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;

pub const Backend = struct {
    install: *Step,
    check: *Step,
    /// The library where CMake builds it, already with its installed rpath.
    library: LazyPath,
    /// The file name the CLI loads the library by, through its rpath.
    name: []const u8,
    /// Builds `library`.
    build: *Step,
};

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    prefix: ?[]const u8,
) Backend {
    const step = b.step("space-backend", "Build and install the optional native OCCT projection library");
    const mode = switch (optimize) {
        .debug => "Debug",
        .safe => "RelWithDebInfo",
        .small => "MinSizeRel",
        .fast => "Release",
    };
    const dir = LazyPath.cache_root.path(
        b,
        b.fmt("occt/{s}-{x}", .{ mode, std.hash.Wyhash.hash(0, prefix orelse "") }),
    );
    const name = if (target.result.os.tag == .macos) "libhuak_space.dylib" else "libhuak_space.so";
    const library = dir.path(b, mode).path(b, name);
    const host = b.graph.host.result;
    if (target.result.cpu.arch != host.cpu.arch or target.result.os.tag != host.os.tag or target.result.abi != host.abi) {
        const fail = &b.addFail("build the OCCT projection library with the target system's C++ toolchain").step;
        step.dependOn(fail);
        return .{
            .install = step,
            .check = fail,
            .library = library,
            .name = name,
            .build = fail,
        };
    }
    const configure = b.addSystemCommand(&.{ "cmake", "-S" });
    configure.addDirectoryArg2(b.path("src/drawing/space"), .{});
    configure.addArg("-B");
    configure.addDirectoryArg2(dir, .{});
    configure.addArg(b.fmt("-DCMAKE_BUILD_TYPE={s}", .{mode}));
    // Zig installs this binary directly, so use its deployment rpath at link time.
    configure.addArg("-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON");
    if (prefix) |sdk| {
        configure.addDirectoryArg2(b.graph.cwdRelativePath(sdk), .{
            .prefix = "-DOpenCASCADE_ROOT=",
            .make_absolute = true,
        });
        // A local SDK can live outside the system loader's search path.
        configure.addArg("-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON");
    }
    const compile = b.addSystemCommand(&.{ "cmake", "--build" });
    compile.addDirectoryArg2(dir, .{});
    compile.addArgs(&.{ "--config", mode, "--parallel", "--target", "huak_space" });
    compile.step.dependOn(&configure.step);
    const install = b.addInstallLibFile(library, name);
    install.step.dependOn(&compile.step);
    step.dependOn(&install.step);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("src/drawing/space/licenses"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/huak/occt",
    }).step);
    const check = b.addSystemCommand(&.{ "cmake", "--build" });
    check.addDirectoryArg2(dir, .{});
    check.addArgs(&.{ "--config", mode, "--target", "check" });
    check.step.dependOn(&compile.step);
    return .{
        .install = step,
        .check = &check.step,
        .library = library,
        .name = name,
        .build = &compile.step,
    };
}
