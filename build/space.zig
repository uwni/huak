//! Builds `libhuak_space` (with OCCT statically linked) and its C++ unit/loader tests.
const std = @import("std");
const occt_build = @import("occt.zig");
const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;

const adapter_sources = [_][]const u8{
    "model.cpp",
    "projection.cpp",
    "view_curves.cpp",
    "view_arrange.cpp",
    "view_cells.cpp",
    "view_regions.cpp",
    "arrangement.cpp",
    "arrangement_polyline.cpp",
    "arrangement_nearest.cpp",
    "arrangement_stretches.cpp",
    "arrangement_crossings.cpp",
    "arrangement_arcs.cpp",
    "curves.cpp",
    "sights.cpp",
    "sights_grid.cpp",
    "contours.cpp",
    "contour_boundary.cpp",
    "contour_fit.cpp",
    "contour_function.cpp",
    "contour_grid.cpp",
    "contour_pieces.cpp",
};

const adapter_flags = [_][]const u8{
    "-std=c++17",
    "-fexceptions",
    "-frtti",
    "-fvisibility=hidden",
    "-fvisibility-inlines-hidden",
    "-ffunction-sections",
    "-fdata-sections",
    "-DOCCT_STATIC_BUILD",
    "-Wno-deprecated-declarations",
};

pub const Backend = struct {
    install: *Step,
    check: *Step,
    /// The compiled projection shared library.
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
) Backend {
    const step = b.step("space-backend", "Build and install the native OCCT projection library");
    const name = if (target.result.os.tag == .macos) "libhuak_space.dylib" else "libhuak_space.so";
    const occt = occt_build.build(b, target, optimize);

    const shared_mod = adapterModule(b, target, optimize, occt);
    const library = b.addLibrary(.{
        .name = "huak_space",
        .linkage = .dynamic,
        .root_module = shared_mod,
    });
    library.link_gc_sections = true;
    if (target.result.os.tag == .macos) {
        library.install_name = "@rpath/libhuak_space.dylib";
    }

    const install = b.addInstallArtifact(library, .{});
    step.dependOn(&install.step);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("src/drawing/space/licenses"),
        .install_dir = .prefix,
        .install_subdir = "share/licenses/huak/occt",
    }).step);

    const objects = b.addLibrary(.{
        .name = "huak_space_objects",
        .linkage = .static,
        .root_module = adapterModule(b, target, optimize, occt),
    });

    const check = b.step("test-space-cpp", "Run native OCCT C++ unit and loader tests");
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "space_projection_test", .source = "tests/space_projection.cpp" },
        .{ .name = "space_contour_function_test", .source = "tests/space_contour_function.cpp" },
        .{ .name = "space_regions_test", .source = "tests/space_regions.cpp" },
    }) |spec| {
        const test_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
        });
        test_mod.addCSourceFile(.{
            .file = b.path(spec.source),
            .flags = &adapter_flags,
        });
        test_mod.linkLibrary(objects);
        occt.linkInto(test_mod);
        const exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = test_mod,
        });
        exe.link_gc_sections = true;
        check.dependOn(&b.addRunArtifact(exe).step);
    }

    const loader_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    loader_mod.addCSourceFile(.{
        .file = b.path("tests/space_loader.cpp"),
        .flags = &.{ "-std=c++17", "-fexceptions" },
    });
    const loader = b.addExecutable(.{
        .name = "space_loader",
        .root_module = loader_mod,
    });
    const run_loader = b.addRunArtifact(loader);
    run_loader.addFileArg(library.getEmittedBin());
    check.dependOn(&run_loader.step);

    const custom_loader = b.addRunArtifact(loader);
    custom_loader.addPassthruArgs();
    b.step("run-space-loader", "Verify a packaged projection shared library with space_loader").dependOn(&custom_loader.step);

    return .{
        .install = step,
        .check = check,
        .library = library.getEmittedBin(),
        .name = name,
        .build = &library.step,
    };
}

fn adapterModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    occt: occt_build.Library,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    mod.addCSourceFiles(.{
        .root = b.path("src/drawing/space"),
        .files = &adapter_sources,
        .flags = &adapter_flags,
    });
    occt.linkInto(mod);
    return mod;
}
