const std = @import("std");
const space_build = @import("build/space.zig");
const rust = @import("build/rust.zig");
const Import = std.Build.Module.Import;
const playground = @import("build/playground.zig");
const Configuration = @import("build/Configuration.zig");
const module_graph = @import("build/modules.zig");
const executables = @import("build/executables.zig");
const benchmarks = @import("build/benchmarks.zig");
const lint = @import("build/lint.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    playground.addPlayground(b);
    const name = switch (target.result.os.tag) {
        .macos => "libtypst.dylib",
        .linux => "libtypst.so",
        else => {
            b.getInstallStep().dependOn(&b.addFail("huak desktop currently supports macOS and Linux").step);
            return;
        },
    };
    const prebuilt = b.option(
        []const u8,
        "libtypst",
        "Use an independently built libtypst instead of building it",
    );
    const typst = rust.libtypst(
        b,
        target,
        optimize,
        name,
        prebuilt,
    );
    b.getInstallStep().dependOn(typst.install);
    const tools = b.step(
        "tools",
        "Build and install the desktop executables",
    );
    b.getInstallStep().dependOn(tools);
    // Zig 0.17's x86_64 ELF backend emits unresolved debug references for C
    // function types; LLVM correctly keeps dynamically bound symbols unlinked.
    const config: Configuration = .{
        .target = target,
        .optimize = optimize,
        .typst = typst,
        .use_llvm = if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) true else null,
    };

    const modules = module_graph.addModules(b, config);
    const runtime_options = b.addOptions();
    const runtime_name = if (target.result.os.tag == .macos) b.fmt("@rpath/{s}", .{name}) else name;

    runtime_options.addOption(
        []const u8,
        "library_path",
        b.option(
            []const u8,
            "runtime-libtypst",
            "Override the installed tools' default libtypst name or path",
        ) orelse runtime_name,
    );
    const desktop: Import = .{
        .name = "host_options",
        .module = runtime_options.createModule(),
    };
    const backend = space_build.build(
        b,
        target,
        optimize,
    );
    const cli = executables.addCli(
        b,
        config,
        modules,
        desktop,
        tools,
    );
    b.getInstallStep().dependOn(backend.install);
    const run = executables.runInstalled(
        b,
        config,
        cli,
        backend.install,
    );
    run.addPassthruArgs();
    b.step("run", "Run the huak script CLI").dependOn(&run.step);
    const editors = executables.addEditorTools(
        b,
        config,
        modules,
        desktop,
        tools,
    );
    const fixtures = module_graph.fixtureModules(
        b,
        config,
        modules,
    );
    executables.addExamples(
        b,
        config,
        modules,
        fixtures,
        desktop,
    );
    benchmarks.addBenchmarks(
        b,
        config,
        modules,
        fixtures,
        cli,
        backend.install,
        desktop,
    );
    tests.addTests(
        b,
        config,
        modules,
        fixtures,
        cli.artifact,
        editors,
    );
    tests.addSpaceTests(
        b,
        config,
        modules,
        cli.artifact,
        backend,
    );

    lint.addLint(b);
}
