const std = @import("std");
const Translator = @import("translate_c").Translator;
const rust = @import("../../../build/rust.zig");

pub fn link(b: *std.Build, consumer: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--locked", "--release", "--lib", "--manifest-path" });
    cargo.addFileArg(b.path("src/render/pdf/Cargo.toml"));
    cargo.addArgs(&.{"--target-dir"});
    const output = cargo.addOutputDirectoryArg("mesh");
    cargo.addFileInput(b.path("src/render/pdf/Cargo.lock"));
    cargo.addFileInput(b.path("src/render/pdf/encode.rs"));
    consumer.addObjectFile(rust.setTarget(b, cargo, target.result, output).path(b, "release/libhuak_pdf_mesh.a"));
    const header: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("src/render/pdf/mesh.h"), .target = target, .optimize = optimize });
    consumer.addImport("pdf_mesh_c", header.mod);
}
