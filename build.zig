const std = @import("std");
const space_contracts = [_][]const u8{ "visibility", "modeling" };
const Translator = @import("translate_c").Translator;
const Import = std.Build.Module.Import;
const Configuration = struct { target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, library: std.Build.LazyPath, use_llvm: ?bool, occt: ?[]const u8 };
const Libraries = struct { binding: Import, native: Import, huak: Import, tooling: Import, options: Import, xml: *std.Build.Module };
const EditorTools = struct { formatter: *std.Build.Step.Compile, language_server: *std.Build.Step.Compile };
const Scenes = struct { sample: Import, drawing: Import, animation: Import, drawing_workflow: Import, typst_workflow: Import };
const Program = struct { name: []const u8, source: []const u8, step: []const u8, description: []const u8, imports: []const Import };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    addPlayground(b);
    const library = libraryPath(b, target) orelse {
        b.getInstallStep().dependOn(&b.addFail("huak desktop currently supports macOS and Linux").step);
        return;
    };
    // Zig 0.17's x86_64 ELF backend emits unresolved debug references for C
    // function types; LLVM correctly keeps dynamically bound symbols unlinked.
    const config: Configuration = .{ .target = target, .optimize = optimize, .library = library, .use_llvm = if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) true else null, .occt = b.option([]const u8, "occt", "OCCT installation prefix for native 3D projection") };

    const libraries = addLibraries(b, config);
    if (config.occt != null)
        b.installDirectory(.{ .source_dir = b.path("src/drawing/space/licenses"), .install_dir = .prefix, .install_subdir = "share/licenses/huak/occt" });
    const cli = addCli(b, config, libraries);
    const editors = addEditorTools(b, config, libraries);
    const scenes = sceneModules(b, config, libraries);
    addExamples(b, config, libraries, scenes);
    addBenchmarks(b, config, libraries, scenes, cli);
    addTests(b, config, libraries, scenes, cli, editors);
    addRegionTests(b, config);
}

fn addRegionTests(b: *std.Build, config: Configuration) void {
    const drawing = module(b, config.target, config.optimize, "src/drawing/root.zig", &.{});
    const region_fixtures = module(b, config.target, config.optimize, "tests/fixtures/regions/root.zig", &.{.{ .name = "drawing", .module = drawing }});
    const root = module(b, config.target, config.optimize, "tests/region/regressions.zig", &.{.{ .name = "region_fixtures", .module = region_fixtures }});
    const regressions = b.addRunArtifact(b.addTest(.{ .root_module = root, .use_llvm = config.use_llvm }));
    b.step("test-region", "Run original curve Boolean precision and degeneracy regressions").dependOn(&regressions.step);
    const contracts = module(b, config.target, config.optimize, "tests/region.zig", &.{.{ .name = "drawing", .module = drawing }});
    const operation_tests = b.addRunArtifact(b.addTest(.{ .root_module = contracts, .use_llvm = config.use_llvm }));
    b.step("test-region-operations", "Test all region, stroke, offset and profile contracts").dependOn(&operation_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&regressions.step);
    b.top_level_steps.get("test").?.step.dependOn(&operation_tests.step);
}

fn libraryPath(b: *std.Build, target: std.Build.ResolvedTarget) ?std.Build.LazyPath {
    if (b.option([]const u8, "libtypst", "Path to an independently built libtypst dynamic library")) |path| return b.graph.cwdRelativePath(path);
    const name = switch (target.result.os.tag) {
        .macos => "libtypst.dylib",
        .linux => "libtypst.so",
        else => return null,
    };
    return b.path(b.fmt("libtypst/target/debug/{s}", .{name}));
}

const EngineModules = struct {
    binding: Import,
    native: Import,
    huak: Import,
    standard_library: Import,
    csv: Import,
    xml: *std.Build.Module,
};

fn engineModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, comptime public: bool, occt: ?[]const u8) EngineModules {
    const c_api: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("libtypst/include/libtypst.h"), .target = target, .optimize = optimize });
    const binding = engineModule(b, public, "typst_binding", .{ .root_source_file = b.path("src/typst/binding.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "typst_c", .module = c_api.mod }} });
    const native = engineModule(b, public, "libtypst", .{ .root_source_file = b.path("src/typst/library.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{binding} });
    const xml = b.dependency("xml", .{ .target = target, .optimize = optimize }).module("xml");
    const csv: Import = .{ .name = "csvzero", .module = b.dependency("csvzero", .{ .target = target, .optimize = optimize }).module("csvzero") };
    const standard_library: Import = .{ .name = "huak_std", .module = b.createModule(.{ .root_source_file = b.path("stdlib/catalog.zig"), .target = target, .optimize = optimize }) };
    const engine = engineModule(b, public, "huak", .{ .root_source_file = b.path("src/huak.zig"), .target = target, .optimize = optimize, .imports = &.{ native, .{ .name = "xml_parser", .module = xml }, standard_library, csv } });
    configureSpace(b, engine.module, target, optimize, occt);
    return .{ .binding = binding, .native = native, .huak = engine, .standard_library = standard_library, .csv = csv, .xml = xml };
}

fn engineModule(b: *std.Build, comptime public: bool, name: []const u8, options: std.Build.Module.CreateOptions) Import {
    return .{ .name = name, .module = if (public) b.addModule(name, options) else b.createModule(options) };
}

fn configureSpace(b: *std.Build, kernel: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, prefix_option: ?[]const u8) void {
    if (prefix_option) |prefix| {
        const header: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("src/drawing/space/projection.h"), .target = target, .optimize = optimize });
        kernel.addImport("space_c", header.mod);
        if (target.result.os.tag == .wasi)
            return @import("apps/playground/space_build.zig").link(b, kernel, b.graph.cwdRelativePath(prefix));
        kernel.addSystemIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ prefix, "include", "opencascade" })));
        kernel.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ prefix, "lib" })));
        kernel.addCSourceFiles(.{ .root = b.path("src/drawing/space"), .files = &.{ "model.cpp", "projection.cpp", "visibility.cpp", "curves.cpp" }, .flags = &.{"-std=c++17"} });
        kernel.link_libcpp = true;
        for ([_][]const u8{ "TKOffset", "TKBO", "TKShHealing", "TKHLR", "TKPrim", "TKTopAlgo", "TKBRep", "TKGeomAlgo", "TKGeomBase", "TKG3d", "TKG2d", "TKMath", "TKernel" }) |lib| kernel.linkSystemLibrary(lib, .{});
    } else {
        kernel.addAnonymousImport("space_c", .{ .root_source_file = b.path("src/drawing/space/disabled.zig") });
    }
}

fn addLibraries(b: *std.Build, config: Configuration) Libraries {
    const engine = engineModules(b, config.target, config.optimize, true, config.occt);
    const tooling = b.addModule("huak_tooling", .{ .root_source_file = b.path("src/tooling.zig"), .target = config.target, .optimize = config.optimize, .link_libc = true, .imports = &.{ engine.native, engine.standard_library, engine.csv } });
    const defaults = b.addOptions();
    if (b.option([]const u8, "runtime-libtypst", "Default library name or path for the installed desktop tools")) |path|
        defaults.addOption([]const u8, "library_path", path)
    else
        defaults.addOptionPathUntracked("library_path", config.library);
    return .{ .binding = engine.binding, .native = engine.native, .huak = engine.huak, .tooling = .{ .name = "huak_tooling", .module = tooling }, .options = .{ .name = "host_options", .module = defaults.createModule() }, .xml = engine.xml };
}

fn addPlayground(b: *std.Build) void {
    const step = b.step("playground", "Build the standalone browser Playground");
    const occt = b.option([]const u8, "wasm-occt", "Directory containing the optional OCCT WASI kernel and its matching toolchain");
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi, .cpu_features_add = if (occt != null) std.Target.wasm.featureSet(&.{.exception_handling}) else .empty });
    const modules = engineModules(b, target, .ReleaseSmall, false, occt);
    const app = b.addExecutable(.{ .name = "huak", .root_module = module(b, target, .ReleaseSmall, "apps/playground/main.zig", &.{ modules.huak, modules.native }), .use_llvm = true });
    const wasi = b.dependency("browser_wasi", .{});
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = wasi.path("dist"), .include_extensions = &.{".js"}, .install_dir = .prefix, .install_subdir = "playground/wasi" }).step);
    step.dependOn(&b.addInstallFile(wasi.path("LICENSE-MIT"), "playground/wasi/LICENSE-MIT").step);
    const cargo = b.addSystemCommand(&.{ "cargo", "rustc", "--locked", "--release", "--lib", "--target", "wasm32-wasip1", "--crate-type", "staticlib" });
    cargo.setCwd(b.path("libtypst"));
    cargo.addArgs(&.{ "--target-dir", "target" });
    app.step.dependOn(&cargo.step);
    app.root_module.addObjectFile(b.path("libtypst/target/wasm32-wasip1/release/libtypst.a"));
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
    for (space_contracts) |name| tests.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("tests/fixtures/space/{s}.huak", .{name})) });
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
    step.dependOn(&b.addInstallFile(b.path("editors/vscode/syntaxes/huak.tmLanguage.json"), "playground/syntax/huak.json").step);
    step.dependOn(&b.addInstallFile(grammars.path("grammars/typst.json"), "playground/syntax/typst.json").step);
    step.dependOn(&b.addInstallFile(themes.path("themes/light-plus.json"), "playground/syntax/light-plus.json").step);
    for ([_][]const u8{ "LICENSE", "NOTICE" }) |file| {
        step.dependOn(&b.addInstallFile(grammars.path(file), b.fmt("playground/syntax/grammars-{s}", .{file})).step);
        step.dependOn(&b.addInstallFile(themes.path(file), b.fmt("playground/syntax/themes-{s}", .{file})).step);
    }
}

fn addCli(b: *std.Build, config: Configuration, libraries: Libraries) *std.Build.Step.Compile {
    const clap: Import = .{ .name = "clap", .module = b.dependency("clap", .{ .target = config.target, .optimize = config.optimize }).module("clap") };
    const app = b.addExecutable(.{ .name = "huak", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "cli/main.zig", &.{ libraries.huak, libraries.native, libraries.options, clap }) });
    b.installArtifact(app);
    const command = b.addRunArtifact(app);
    command.addPassthruArgs();
    b.step("run", "Run the huak script CLI").dependOn(&command.step);
    return app;
}

fn addEditorTools(b: *std.Build, config: Configuration, libraries: Libraries) EditorTools {
    const clap: Import = .{ .name = "clap", .module = b.dependency("clap", .{ .target = config.target, .optimize = config.optimize }).module("clap") };
    const imports = &.{ libraries.tooling, libraries.options, clap };
    const formatter = b.addExecutable(.{ .name = "huak-fmt", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "apps/formatter/main.zig", imports) });
    const language_server = b.addExecutable(.{ .name = "huak-lsp", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "apps/language_server/main.zig", imports) });
    const install_formatter = b.addInstallArtifact(formatter, .{});
    const install_server = b.addInstallArtifact(language_server, .{});
    b.getInstallStep().dependOn(&install_formatter.step);
    b.getInstallStep().dependOn(&install_server.step);
    b.step("formatter", "Build and install the standalone formatter").dependOn(&install_formatter.step);
    b.step("language-server", "Build and install the standalone language server").dependOn(&install_server.step);
    return .{ .formatter = formatter, .language_server = language_server };
}

fn sceneModules(b: *std.Build, config: Configuration, libraries: Libraries) Scenes {
    const native = libraries.native;
    const huak = libraries.huak;
    const sample: Import = .{ .name = "typst_sample", .module = module(b, config.target, config.optimize, "examples/scenes/typst.zig", &.{}) };
    const drawing: Import = .{ .name = "drawing_scene", .module = module(b, config.target, config.optimize, "examples/scenes/drawing.zig", &.{ huak, native }) };
    const animation: Import = .{ .name = "animation_scene", .module = module(b, config.target, config.optimize, "examples/scenes/animation.zig", &.{ huak, native, drawing }) };
    const drawing_workflow: Import = .{ .name = "drawing_workflow", .module = module(b, config.target, config.optimize, "examples/support/drawing.zig", &.{ huak, native, drawing }) };
    const typst_workflow: Import = .{ .name = "typst_workflow", .module = module(b, config.target, config.optimize, "examples/support/typst.zig", &.{native}) };
    return .{ .sample = sample, .drawing = drawing, .animation = animation, .drawing_workflow = drawing_workflow, .typst_workflow = typst_workflow };
}

fn addExamples(b: *std.Build, config: Configuration, libraries: Libraries, scenes: Scenes) void {
    const install = b.step("examples", "Build and install programmatic examples");
    const programs = [_]Program{
        .{ .name = "huak-drawing", .source = "examples/drawing.zig", .step = "run-drawing", .description = "Render a native mathematical picture", .imports = &.{ libraries.native, scenes.drawing_workflow, libraries.options } },
        .{ .name = "huak-typst", .source = "examples/typst.zig", .step = "run-typst", .description = "Compile an in-memory Typst document", .imports = &.{ libraries.native, scenes.sample, scenes.typst_workflow, libraries.options } },
        .{ .name = "huak-outlines", .source = "examples/outlines.zig", .step = "run-outlines", .description = "Edit laid-out glyph outlines", .imports = &.{ libraries.native, libraries.huak, libraries.options } },
        .{ .name = "huak-animation", .source = "examples/animation.zig", .step = "run-animation", .description = "Export continuous SVG animation", .imports = &.{ libraries.native, libraries.huak, scenes.animation, libraries.options } },
    };
    for (programs) |spec| install.dependOn(&b.addInstallArtifact(program(b, config, spec), .{}).step);
}

fn addBenchmarks(b: *std.Build, config: Configuration, libraries: Libraries, scenes: Scenes, cli: *std.Build.Step.Compile) void {
    const clap: Import = .{ .name = "clap", .module = b.dependency("clap", .{ .target = config.target, .optimize = config.optimize }).module("clap") };
    const resources: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("bench/support/resources.h"), .target = config.target, .optimize = config.optimize });
    const metrics: Import = .{ .name = "metrics", .module = module(b, config.target, config.optimize, "bench/support/metrics.zig", &.{.{ .name = "resources", .module = resources.mod }}) };
    const drawing_core: Import = .{ .name = "drawing", .module = module(b, config.target, config.optimize, "src/drawing/root.zig", &.{}) };
    const region_fixtures: Import = .{ .name = "region_fixtures", .module = module(b, config.target, config.optimize, "tests/fixtures/regions/root.zig", &.{drawing_core}) };
    _ = program(b, config, .{ .name = "bench-regions", .source = "bench/regions.zig", .step = "bench-regions", .description = "Measure validated f64 curve-region operations", .imports = &.{ region_fixtures, metrics, clap } });
    _ = program(b, config, .{ .name = "bench-regions-compare", .source = "bench/regions_compare.zig", .step = "bench-regions-compare", .description = "Compare already-built region benchmarks in balanced serial rounds", .imports = &.{clap} });
    const programs = [_]Program{
        .{ .name = "bench-compare", .source = "bench/compare.zig", .step = "bench-compare", .description = "Compare two CLI binaries with paired timing, RSS and output hashes", .imports = &.{} },
        .{ .name = "bench-drawing", .source = "bench/drawing.zig", .step = "bench-drawing", .description = "Measure native drawing construction", .imports = &.{ libraries.native, scenes.drawing_workflow, libraries.options, metrics } },
        .{ .name = "bench-typst", .source = "bench/typst.zig", .step = "bench-typst", .description = "Measure in-memory Typst compilation", .imports = &.{ libraries.native, scenes.sample, scenes.typst_workflow, libraries.options, metrics } },
        .{ .name = "bench-language", .source = "bench/language.zig", .step = "bench-language", .description = "Measure compilation, VM reuse and drawing", .imports = &.{ libraries.native, libraries.huak, libraries.options, metrics } },
        .{ .name = "bench-pen-motion", .source = "bench/pen_motion.zig", .step = "bench-pen-motion", .description = "Measure continuous moving nib envelopes", .imports = &.{libraries.huak} },
        .{ .name = "bench-brushes", .source = "bench/brushes.zig", .step = "bench-brushes", .description = "Investigate brushes compilation, construction and export phases", .imports = &.{ libraries.native, libraries.huak, metrics } },
        .{ .name = "bench-plot", .source = "packages/plot/bench/native.zig", .step = "bench-plot", .description = "Measure independent plot package construction and vector export", .imports = &.{ libraries.native, libraries.huak, libraries.options, metrics } },
        .{ .name = "bench-brushes-process", .source = "bench/brushes_process.zig", .step = "bench-brushes-process", .description = "Measure brushes fresh CLI and watch processes", .imports = &.{metrics} },
        .{ .name = "bench-workers", .source = "bench/workers.zig", .step = "bench-workers", .description = "Compare automatic construction workers with serial execution", .imports = &.{ libraries.native, libraries.huak, libraries.options, metrics } },
        .{ .name = "bench-typst-parallel", .source = "bench/typst_parallel.zig", .step = "bench-typst-parallel", .description = "Compare serial and batched native typography", .imports = &.{ libraries.native, libraries.huak, libraries.options, metrics } },
        .{ .name = "bench-outlines", .source = "bench/outlines.zig", .step = "bench-outlines", .description = "Measure native outline transfer", .imports = &.{ libraries.native, libraries.huak, libraries.options, metrics } },
        .{ .name = "bench-animation", .source = "bench/animation.zig", .step = "bench-animation", .description = "Measure continuous animation export", .imports = &.{ libraries.native, libraries.huak, scenes.animation, libraries.options, metrics } },
        .{ .name = "bench-pen-envelope", .source = "bench/pen_envelope.zig", .step = "bench-pen-envelope", .description = "Measure convex-nib curve envelopes", .imports = &.{libraries.huak} },
        .{ .name = "bench-pen-compare", .source = "bench/pen_compare.zig", .step = "bench-pen-compare", .description = "Compare envelope speed and memory with MetaPost", .imports = &.{ drawing_core, metrics } },
    };
    for (programs) |spec| _ = program(b, config, spec);
    const copies = b.addExecutable(.{ .name = "bench-copies", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "bench/copies.zig", &.{ libraries.native, libraries.huak, libraries.options, metrics }) });
    const copies_run = b.addRunArtifact(copies);
    copies_run.addPassthruArgs();
    b.step("bench-copies", "Measure copy and temporary-object elimination").dependOn(&copies_run.step);
    const copies_install = b.addInstallArtifact(copies, .{});
    b.step("build-bench-copies", "Build the copy-elimination benchmark").dependOn(&copies_install.step);
    const batch = b.addExecutable(.{ .name = "bench-outputs", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "bench/outputs.zig", &.{}) });
    const batch_run = b.addRunArtifact(batch);
    batch_run.addArtifactArg(cli);
    batch_run.addFileArg(config.library);
    batch_run.addPassthruArgs();
    b.step("bench-outputs", "Compare serial and parallel multi-output CLI execution").dependOn(&batch_run.step);
    const simd_api = b.createModule(.{ .root_source_file = b.path("src/drawing/simd.zig"), .target = config.target, .optimize = .ReleaseSafe });
    const simd = b.addExecutable(.{ .name = "bench-simd", .use_llvm = config.use_llvm, .root_module = module(b, config.target, .ReleaseSafe, "bench/simd.zig", &.{.{ .name = "simd", .module = simd_api }}) });
    b.step("bench-simd", "Compare scalar and SIMD transforms").dependOn(&b.addRunArtifact(simd).step);
}

fn addTests(b: *std.Build, config: Configuration, libraries: Libraries, scenes: Scenes, cli: *std.Build.Step.Compile, editors: EditorTools) void {
    const native = libraries.native;
    const huak = libraries.huak;
    const sample = scenes.sample;
    const drawing = scenes.drawing;
    const clap: Import = .{ .name = "clap", .module = b.dependency("clap", .{ .target = config.target, .optimize = config.optimize }).module("clap") };
    const fixture_options = b.addOptions();
    fixture_options.addOptionPath("library_path", config.library);
    fixture_options.addOptionPath("incompatible_path", fixture(b, config, "incompatible", true).getEmittedBin());
    fixture_options.addOptionPath("incomplete_path", fixture(b, config, "incomplete", false).getEmittedBin());
    const loader_options: Import = .{ .name = "test_options", .module = fixture_options.createModule() };
    const test_options: Import = .{ .name = "test_options", .module = libraries.options.module };
    const all_tests = b.step("test", "Run all unit and native integration tests");
    const language_tests = b.step("test-language", "Test the script language and native rendering");
    const animation_tests = b.step("test-animation", "Test animation encoding and native rendering");
    const region_tests = b.step("test-region-geometry", "Test curve regions with their drawing dependencies");
    const suites = [_]struct { source: []const u8, name: []const u8, imports: []const Import, native: bool = true, group: ?*std.Build.Step = null }{
        .{ .source = "tests/native_binding.zig", .name = "test-native-binding", .imports = &.{ libraries.binding, test_options } },
        .{ .source = "tests/typst.zig", .name = "test-typst", .imports = &.{ native, sample, loader_options } },
        .{ .source = "tests/language.zig", .name = "test-language-native", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/math.zig", .name = "test-math", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/aggregates.zig", .name = "test-language-aggregates", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/output_batch.zig", .name = "test-output-batch", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/workers.zig", .name = "test-workers", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/typst_parallel.zig", .name = "test-typst-parallel", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/units.zig", .name = "test-units", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/standard_library.zig", .name = "test-standard-library", .imports = &.{ native, huak, test_options }, .group = language_tests },
        .{ .source = "tests/drawing.zig", .name = "test-drawing", .imports = &.{ native, huak, drawing, test_options } },
        .{ .source = "tests/pens.zig", .name = "test-pen-envelope", .imports = &.{huak}, .native = false },
        .{ .source = "tests/regions.zig", .name = "test-region-render", .imports = &.{ native, huak, test_options } },
        .{ .source = "tests/outlines.zig", .name = "test-outlines", .imports = &.{ native, huak, test_options } },
        .{ .source = "tests/animation.zig", .name = "test-animation-native", .imports = &.{ native, huak, test_options }, .group = animation_tests },
        .{ .source = "tests/abi.zig", .name = "test-abi", .imports = &.{ native, libraries.binding, huak, test_options } },
        .{ .source = "cli/options.zig", .name = "test-cli-options", .imports = &.{clap}, .native = false },
        .{ .source = "bench/regions_compare.zig", .name = "test-region-benchmark", .imports = &.{clap}, .native = false },
        .{ .source = "src/drawing/root.zig", .name = "test-geometry", .imports = &.{}, .native = false, .group = region_tests },
    };
    inline for (suites) |suite| {
        const root = module(b, config.target, config.optimize, suite.source, suite.imports);
        const command = b.addRunArtifact(b.addTest(.{ .root_module = root, .use_llvm = config.use_llvm }));
        if (suite.native) command.addFileInput(config.library);
        all_tests.dependOn(&command.step);
        if (suite.group) |group| group.dependOn(&command.step);
        b.step(suite.name, b.fmt("Run {s}", .{suite.source})).dependOn(&command.step);
    }
    const pure = b.addRunArtifact(b.addTest(.{ .root_module = libraries.huak.module, .use_llvm = config.use_llvm }));
    all_tests.dependOn(&pure.step);
    language_tests.dependOn(&pure.step);
    animation_tests.dependOn(&pure.step);
    b.step("test-animation-encoding", "Test geometry, language and SVG encoding without loading libtypst").dependOn(&pure.step);
    b.step("test-backend", "Test rendering adapters with their engine dependencies").dependOn(&pure.step);
    const cli_options = b.addOptions();
    cli_options.addOptionPath("executable_path", cli.getEmittedBin());
    cli_options.addOptionPath("library_path", config.library);
    const cli_root = module(b, config.target, config.optimize, "tests/cli.zig", &.{ .{ .name = "test_options", .module = cli_options.createModule() }, .{ .name = "xml_parser", .module = libraries.xml } });
    const cli_tests = b.addRunArtifact(b.addTest(.{ .root_module = cli_root, .use_llvm = config.use_llvm }));
    cli_tests.addFileInput(config.library);
    all_tests.dependOn(&cli_tests.step);
    language_tests.dependOn(&cli_tests.step);
    b.step("test-cli", "Run real CLI processes and verify SVG/PDF output").dependOn(&cli_tests.step);
    if (config.occt != null) {
        const space = b.step("test-space", "Test modeling and projected visibility in SVG and PDF");
        all_tests.dependOn(space);
        for (space_contracts) |name| {
            const projection = b.addRunArtifact(cli);
            projection.addArg("run");
            projection.addFileArg(b.path(b.fmt("tests/fixtures/space/{s}.huak", .{name})));
            projection.addArg("--libtypst");
            projection.addFileArg(config.library);
            for ([_][]const u8{ "svg", "pdf" }) |extension| {
                projection.addArg("--output");
                _ = projection.addOutputFileArg2(b.fmt("{s}.{s}", .{ name, extension }), .{});
            }
            space.dependOn(&projection.step);
        }
    }
    const editor_options = b.addOptions();
    editor_options.addOptionPath("library_path", config.library);
    editor_options.addOptionPath("formatter_path", editors.formatter.getEmittedBin());
    editor_options.addOptionPath("language_server_path", editors.language_server.getEmittedBin());
    const editor_tests = b.addRunArtifact(b.addTest(.{ .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "tests/editor_tools.zig", &.{ libraries.tooling, .{ .name = "test_options", .module = editor_options.createModule() } }) }));
    editor_tests.addFileInput(config.library);
    all_tests.dependOn(&editor_tests.step);
    const tools_tests = b.step("test-tools", "Test formatter and language server processes");
    tools_tests.dependOn(&editor_tests.step);
    const tool_units = b.addRunArtifact(b.addTest(.{ .use_llvm = config.use_llvm, .root_module = libraries.tooling.module }));
    tools_tests.dependOn(&tool_units.step);
    all_tests.dependOn(&tool_units.step);
    _ = program(b, config, .{ .name = "animation-references", .source = "tests/animation/references.zig", .step = "verify-animation", .description = "Generate native animation reference fixtures", .imports = &.{ libraries.native, libraries.huak, scenes.animation, libraries.options } });
}

fn program(b: *std.Build, config: Configuration, spec: Program) *std.Build.Step.Compile {
    const app = b.addExecutable(.{ .name = spec.name, .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, spec.source, spec.imports) });
    const command = b.addRunArtifact(app);
    command.addPassthruArgs();
    b.step(spec.step, spec.description).dependOn(&command.step);
    return app;
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, source: []const u8, imports: []const Import) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true, .imports = imports });
}

fn fixture(b: *std.Build, config: Configuration, name: []const u8, incompatible: bool) *std.Build.Step.Compile {
    const root = b.createModule(.{ .target = config.target, .optimize = .Debug, .link_libc = true });
    const headers = b.addWriteFiles();
    const header = headers.addCopyFile(b.path("libtypst/include/libtypst.h"), "libtypst.h");
    root.addIncludePath(header.dirname());
    root.addCSourceFile(.{ .file = b.path("tests/fixtures/typst_loader.c"), .flags = &.{ "-std=c11", if (incompatible) "-DTYPST_TEST_INCOMPATIBLE=1" else "-DTYPST_TEST_INCOMPATIBLE=0" } });
    return b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = root, .use_llvm = config.use_llvm });
}
