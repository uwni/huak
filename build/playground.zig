//! The Playground: its WebAssembly engine and site, the editor files it copies, and its tests.
const std = @import("std");
const rust = @import("rust.zig");
const module_graph = @import("modules.zig");
const executables = @import("executables.zig");
const engineModules = module_graph.engineModules;
const module = module_graph.module;
const editor_grammar = executables.editor_grammar;

pub fn addPlayground(b: *std.Build) void {
    const step = b.step("playground", "Build the standalone browser Playground");
    const occt = b.option([]const u8, "wasm-occt", "Directory containing the optional OCCT WASI kernel and its matching toolchain");
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi, .cpu_features_add = if (occt != null) std.Target.wasm.featureSet(&.{.exception_handling}) else .empty });
    const modules = engineModules(b, target, .ReleaseSmall, false);
    if (occt) |prefix| @import("../apps/playground/space_build.zig").link(b, modules.huak.module, b.graph.cwdRelativePath(prefix));
    const app = b.addExecutable(.{ .name = "huak", .root_module = module(b, target, .ReleaseSmall, "apps/playground/main.zig", &.{ modules.huak, modules.native }), .use_llvm = true });
    const options = b.addOptions();
    options.addOption(bool, "has_projection", occt != null);
    app.root_module.addOptions("playground_options", options);
    const wasi = b.dependency("browser_wasi", .{});
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = wasi.path("dist"), .include_extensions = &.{".js"}, .install_dir = .prefix, .install_subdir = "playground/wasi" }).step);
    step.dependOn(&b.addInstallFile(wasi.path("LICENSE-MIT"), "playground/wasi/LICENSE-MIT").step);
    const cargo = b.addSystemCommand(&.{ "cargo", "rustc", "--locked", "--release", "--lib", "--crate-type", "staticlib" });
    cargo.setCwd(b.path("libtypst"));
    cargo.addArgs(&.{ "--target-dir", "target" });
    app.step.dependOn(&cargo.step);
    const library = rust.setTarget(b, cargo, target.result, b.path("libtypst/target")).path(b, "release/libtypst.a");
    app.root_module.addObjectFile(library);
    const tests = b.addTest(.{ .root_module = app.root_module, .use_llvm = true });
    tests.step.dependOn(&cargo.step);
    tests.stack_size = 8 * 1024 * 1024;
    const check = b.addSystemCommand(&.{"wasmtime"});
    if (occt != null) check.addArg("-Wexceptions=y");
    check.addArtifactArg(tests);
    b.step("test-playground", "Test SVG and diagnostics through the Wasm entry points").dependOn(&check.step);
    app.root_module.export_symbol_names = &.{ "huak_input", "huak_set_files", "huak_render", "huak_result", "huak_result_len" };
    app.wasi_exec_model = .reactor;
    app.stack_size = 8 * 1024 * 1024;
    step.dependOn(&b.addInstallFile(app.getEmittedBin(), "playground/huak.wasm").step);
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("apps/playground/site"), .install_dir = .prefix, .install_subdir = "playground" }).step);
    installPlaygroundEditor(b, step);
    const catalog = b.addRunArtifact(b.addExecutable(.{ .name = "playground-catalog", .root_module = module(b, b.graph.host, .ReleaseSafe, "apps/playground/catalog.zig", &.{}) }));
    const sources = b.addWriteFiles().addCopyDirectory(b.path("examples"), "examples", .{ .include_extensions = &.{ ".huak", ".csv", ".json" } });
    catalog.addDirectoryArg2(sources, .{});
    const index = catalog.addOutputFileArg2("examples.json", .{});
    if (occt != null) catalog.addArg("--space");
    tests.root_module.addAnonymousImport("example-catalog", .{ .root_source_file = index });
    tests.root_module.addAnonymousImport("space_contracts", .{ .root_source_file = b.path("tests/fixtures/space/contracts.zig") });
    if (occt != null) step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("src/drawing/space/licenses"), .install_dir = .prefix, .install_subdir = "playground/licenses/occt" }).step);
    step.dependOn(&b.addInstallFile(index, "playground/examples.json").step);
}

fn installPlaygroundEditor(b: *std.Build, step: *std.Build.Step) void {
    const monaco = b.dependency("monaco", .{});
    const grammars = b.dependency("tm_grammars", .{});
    const themes = b.dependency("tm_themes", .{});
    const modules = [_][]const u8{ "editor-core.mjs", "editor-worker-main.mjs", "editor-worker.mjs", "shiki.mjs", "shiki-wasm.mjs", "cache.mjs", "util.mjs" };
    for (modules) |file| {
        step.dependOn(&b.addInstallFile(monaco.path(b.fmt("dist/{s}", .{file})), b.fmt("playground/monaco/{s}", .{file})).step);
    }
    step.dependOn(&b.addInstallFile(monaco.path("LICENSE"), "playground/monaco/LICENSE").step);
    step.dependOn(&b.addInstallFile(b.path(editor_grammar), "playground/syntax/huak.json").step);
    step.dependOn(&b.addInstallFile(grammars.path("grammars/typst.json"), "playground/syntax/typst.json").step);
    step.dependOn(&b.addInstallFile(themes.path("themes/light-plus.json"), "playground/syntax/light-plus.json").step);
    for ([_][]const u8{ "LICENSE", "NOTICE" }) |file| {
        step.dependOn(&b.addInstallFile(grammars.path(file), b.fmt("playground/syntax/grammars-{s}", .{file})).step);
        step.dependOn(&b.addInstallFile(themes.path(file), b.fmt("playground/syntax/themes-{s}", .{file})).step);
    }
}
