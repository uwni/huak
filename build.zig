const std = @import("std");
const space_build = @import("build/space.zig");
const rust = @import("build/rust.zig");
const Import = std.Build.Module.Import;
const playground = @import("build/playground.zig");
const Configuration = @import("build/Configuration.zig");
const module_graph = @import("build/modules.zig");
const executables = @import("build/executables.zig");
const benchmarks = @import("build/benchmarks.zig");
const tests = @import("build/tests.zig");
const addPlayground = playground.addPlayground;
const addLibraries = module_graph.addLibraries;
const addCli = executables.addCli;
const runInstalled = executables.runInstalled;
const addEditorTools = executables.addEditorTools;
const fixtureModules = module_graph.fixtureModules;
const addExamples = executables.addExamples;
const addBenchmarks = benchmarks.addBenchmarks;
const addTests = tests.addTests;
const addSpaceTests = tests.addSpaceTests;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    addPlayground(b);
    const name = switch (target.result.os.tag) {
        .macos => "libtypst.dylib",
        .linux => "libtypst.so",
        else => {
            b.getInstallStep().dependOn(&b.addFail("huak desktop currently supports macOS and Linux").step);
            return;
        },
    };
    const prebuilt = b.option([]const u8, "libtypst", "Use an independently built libtypst instead of building it");
    const typst = rust.libtypst(b, target, optimize, name, prebuilt);
    b.getInstallStep().dependOn(typst.install);
    const tools = b.step("tools", "Build and install the desktop executables");
    b.getInstallStep().dependOn(tools);
    // Zig 0.17's x86_64 ELF backend emits unresolved debug references for C
    // function types; LLVM correctly keeps dynamically bound symbols unlinked.
    const config: Configuration = .{ .target = target, .optimize = optimize, .typst = typst, .use_llvm = if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) true else null };

    const libraries = addLibraries(b, config);
    const runtime_options = b.addOptions();
    const runtime_name = if (target.result.os.tag == .macos) b.fmt("@rpath/{s}", .{name}) else name;
    runtime_options.addOption([]const u8, "library_path", b.option([]const u8, "runtime-libtypst", "Override the installed tools' default libtypst name or path") orelse runtime_name);
    const desktop: Import = .{ .name = "host_options", .module = runtime_options.createModule() };
    const occt = b.option([]const u8, "occt", "OCCT SDK prefix for building the separate projection library");
    const backend = space_build.build(b, target, optimize, occt);
    const cli = addCli(b, config, libraries, desktop, tools);
    if (occt != null) b.getInstallStep().dependOn(backend.install);
    const run = runInstalled(b, config, cli, if (occt != null) backend.install else null);
    run.addPassthruArgs();
    b.step("run", "Run the huak script CLI").dependOn(&run.step);
    const editors = addEditorTools(b, config, libraries, desktop, tools);
    const fixtures = fixtureModules(b, config, libraries);
    addExamples(b, config, libraries, fixtures, desktop);
    addBenchmarks(b, config, libraries, fixtures, cli, if (occt != null) backend.install else null, desktop);
    addTests(b, config, libraries, fixtures, cli.artifact, editors);
    addSpaceTests(b, config, libraries, cli.artifact, backend, occt != null);
}
