//! Link the prebuilt OCCT WASI kernel with the C++ headers and exception ABI
//! it was built against. The drawing adapter is shared with the desktop.
const std = @import("std");

pub fn link(b: *std.Build, kernel: *std.Build.Module, root: std.Build.LazyPath) void {
    const sdk = root.path(b, "wasi-sdk");
    const syslib = sdk.path(b, "share/wasi-sysroot/lib/wasm32-wasip1");
    for ([_][]const u8{
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
    }) |file| {
        const part = std.Io.Dir.path.stem(file);
        const cc = std.Build.Step.Run.create(b, b.fmt("compile OCCT WASI {s}", .{part}));
        cc.addFileArg(sdk.path(b, "bin/clang++"));
        cc.addArgs(&.{ "--target=wasm32-wasip1", "-std=c++17", "-Os", "-Wno-deprecated-declarations", "-fwasm-exceptions", "-mllvm", "-wasm-use-legacy-eh=false", "-mllvm", "-wasm-enable-sjlj" });
        cc.addDirectoryArg2(root.path(b, "WASI.sdk"), .{ .prefix = "--sysroot=" });
        cc.addArg("-include");
        cc.addFileArg(root.path(b, "wasi-std-threading.hpp"));
        cc.addArg("-isystem");
        cc.addDirectoryArg2(root.path(b, "occt-headers-wasm"), .{});
        cc.addArg("-c");
        cc.addFileArg(b.path("src/drawing/space").path(b, file));
        for ([_][]const u8{ "space.hxx", "projection.h", "view.hxx", "sights.hxx", "arranging.hxx", "contours.hxx", "contour_function.hxx" }) |header|
            cc.addFileInput(b.path("src/drawing/space").path(b, header));
        cc.addArg("-o");
        kernel.addObjectFile(cc.addOutputFileArg2(b.fmt("{s}.o", .{part}), .{}));
    }
    kernel.addObjectFile(root.path(b, "libOCCT-wasm.a"));
    for ([_][]const u8{ "eh/libc++.a", "eh/libc++abi.a", "eh/libunwind.a", "libwasi-emulated-signal.a", "libwasi-emulated-mman.a", "libwasi-emulated-process-clocks.a", "libwasi-emulated-getpid.a" }) |lib|
        kernel.addObjectFile(syslib.path(b, lib));
}
