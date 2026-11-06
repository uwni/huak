const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn link(b: *std.Build, consumer: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    const triple = switch (target.result.os.tag) {
        .macos => b.fmt("{s}-apple-darwin", .{@tagName(target.result.cpu.arch)}),
        .linux => b.fmt("{s}-unknown-linux-{s}", .{ @tagName(target.result.cpu.arch), if (target.result.abi == .musl) "musl" else "gnu" }),
        .wasi => "wasm32-wasip1",
        else => @panic("unsupported PDF mesh target"),
    };
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--locked", "--release", "--lib", "--target", triple, "--manifest-path" });
    cargo.addFileArg(b.path("src/render/pdf/Cargo.toml"));
    cargo.addArgs(&.{"--target-dir"});
    const output = cargo.addOutputDirectoryArg("mesh");
    cargo.addFileInput(b.path("src/render/pdf/Cargo.lock"));
    cargo.addFileInput(b.path("src/render/pdf/encode.rs"));
    consumer.addObjectFile(output.path(b, b.fmt("{s}/release/libhuak_pdf_mesh.a", .{triple})));
    const header: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("src/render/pdf/mesh.h"), .target = target, .optimize = optimize });
    consumer.addImport("pdf_mesh_c", header.mod);
}
