//! Every benchmark step.
const std = @import("std");
const Translator = @import("translate_c").Translator;
const Import = std.Build.Module.Import;
const Configuration = @import("Configuration.zig");
const module_graph = @import("modules.zig");
const executables = @import("executables.zig");
const Modules = module_graph.Modules;
const Fixtures = module_graph.Fixtures;
const module = module_graph.module;
const program = executables.program;
const Program = executables.Program;
const desktopExecutable = executables.desktopExecutable;
const runInstalled = executables.runInstalled;

pub fn addBenchmarks(b: *std.Build, config: Configuration, modules: Modules, fixtures: Fixtures, cli: *std.Build.Step.InstallArtifact, backend: ?*std.Build.Step, desktop: Import) void {
    const resources: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("bench/support/resources.h"), .target = config.target, .optimize = config.optimize });
    const metrics: Import = .{ .name = "metrics", .module = module(b, config.target, config.optimize, "bench/support/metrics.zig", &.{.{ .name = "resources", .module = resources.mod }}) };
    _ = program(b, config, .{ .name = "bench-regions", .source = "bench/regions.zig", .step = "bench-regions", .description = "Measure validated f64 curve-region operations", .imports = &.{ fixtures.regions, metrics, modules.clap } });
    _ = program(b, config, .{ .name = "bench-regions-compare", .source = "bench/regions_compare.zig", .step = "bench-regions-compare", .description = "Compare already-built region benchmarks in balanced serial rounds", .imports = &.{modules.clap} });
    const programs = [_]Program{
        .{ .name = "bench-compare", .source = "bench/compare.zig", .step = "bench-compare", .description = "Compare two CLI binaries with paired timing, RSS and output hashes", .imports = &.{} },
        .{ .name = "bench-drawing", .source = "bench/drawing.zig", .step = "bench-drawing", .description = "Measure native drawing construction", .imports = &.{ modules.native, fixtures.drawing_workflow, modules.options, metrics } },
        .{ .name = "bench-typst", .source = "bench/typst.zig", .step = "bench-typst", .description = "Measure in-memory Typst compilation", .imports = &.{ modules.native, fixtures.sample, fixtures.typst_workflow, modules.options, metrics } },
        .{ .name = "bench-language", .source = "bench/language.zig", .step = "bench-language", .description = "Measure compilation, VM reuse and drawing", .imports = &.{ modules.native, modules.huak, modules.options, metrics } },
        .{ .name = "bench-pen-motion", .source = "bench/pen_motion.zig", .step = "bench-pen-motion", .description = "Measure continuous moving nib envelopes", .imports = &.{modules.huak} },
        .{ .name = "bench-brushes", .source = "bench/brushes.zig", .step = "bench-brushes", .description = "Investigate brushes compilation, construction and export phases", .imports = &.{ modules.native, modules.huak, metrics } },
        .{ .name = "bench-plot", .source = "packages/plot/bench/native.zig", .step = "bench-plot", .description = "Measure independent plot package construction and vector export", .imports = &.{ modules.native, modules.huak, modules.options, metrics } },
        .{ .name = "bench-brushes-process", .source = "bench/brushes_process.zig", .step = "bench-brushes-process", .description = "Measure brushes fresh CLI and watch processes", .imports = &.{metrics} },
        .{ .name = "bench-workers", .source = "bench/workers.zig", .step = "bench-workers", .description = "Compare automatic construction workers with serial execution", .imports = &.{ modules.native, modules.huak, modules.options, metrics } },
        .{ .name = "bench-typst-parallel", .source = "bench/typst_parallel.zig", .step = "bench-typst-parallel", .description = "Compare serial and batched native typography", .imports = &.{ modules.native, modules.huak, modules.options, metrics } },
        .{ .name = "bench-outlines", .source = "bench/outlines.zig", .step = "bench-outlines", .description = "Measure native outline transfer", .imports = &.{ modules.native, modules.huak, modules.options, metrics } },
        .{ .name = "bench-animation", .source = "bench/animation.zig", .step = "bench-animation", .description = "Measure continuous animation export", .imports = &.{ modules.native, modules.huak, fixtures.animation, modules.options, metrics } },
        .{ .name = "bench-pen-envelope", .source = "bench/pen_envelope.zig", .step = "bench-pen-envelope", .description = "Measure convex-nib curve envelopes", .imports = &.{modules.huak} },
        .{ .name = "bench-pen-compare", .source = "bench/pen_compare.zig", .step = "bench-pen-compare", .description = "Compare envelope speed and memory with MetaPost", .imports = &.{ modules.drawing, metrics } },
    };
    for (programs) |spec| _ = program(b, config, spec);
    const copies = b.addInstallArtifact(desktopExecutable(b, config, "bench-copies", "bench/copies.zig", &.{ modules.native, modules.huak, desktop, metrics }), .{});
    const copies_run = runInstalled(b, config, copies, null);
    copies_run.addPassthruArgs();
    b.step("bench-copies", "Measure copy and temporary-object elimination").dependOn(&copies_run.step);
    b.step("build-bench-copies", "Build the copy-elimination benchmark").dependOn(&copies.step);
    const batch = b.addExecutable(.{ .name = "bench-outputs", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "bench/outputs.zig", &.{}) });
    const batch_run = b.addRunArtifact(batch);
    config.typst.loadIn(batch_run);
    batch_run.addArtifactArg(cli.artifact);
    batch_run.addFileArg(config.typst.library);
    batch_run.addPassthruArgs();
    b.step("bench-outputs", "Compare serial and parallel multi-output CLI execution").dependOn(&batch_run.step);
    const space_bench = b.addExecutable(.{ .name = "bench-space", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "bench/space.zig", &.{}) });
    const space_run = b.addRunArtifact(space_bench);
    space_run.addFileArg2(b.graph.path(.install_bin, cli.artifact.name), .{});
    space_run.step.dependOn(&cli.step);
    space_run.step.dependOn(config.typst.install);
    if (backend) |install| space_run.step.dependOn(install);
    space_run.addPassthruArgs();
    b.step("bench-space", "Measure 3D projection, smooth shading and Type 7/SVG mesh export").dependOn(&space_run.step);
    const simd_api = b.createModule(.{ .root_source_file = b.path("src/drawing/simd.zig"), .target = config.target, .optimize = .ReleaseSafe });
    const simd = b.addExecutable(.{ .name = "bench-simd", .use_llvm = config.use_llvm, .root_module = module(b, config.target, .ReleaseSafe, "bench/simd.zig", &.{.{ .name = "simd", .module = simd_api }}) });
    b.step("bench-simd", "Compare scalar and SIMD transforms").dependOn(&b.addRunArtifact(simd).step);
}
