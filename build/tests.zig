//! Unit, integration and acceptance tests, and the OCCT projection tests.
const std = @import("std");
const space_contracts = @import("../tests/fixtures/space/contracts.zig");
const space_build = @import("space.zig");
const Import = std.Build.Module.Import;
const Configuration = @import("Configuration.zig");
const module_graph = @import("modules.zig");
const executables = @import("executables.zig");
const Libraries = module_graph.Libraries;
const Fixtures = module_graph.Fixtures;
const EditorTools = executables.EditorTools;
const module = module_graph.module;
const editor_grammar = executables.editor_grammar;
const editor_configuration = executables.editor_configuration;
const program = executables.program;

pub fn addTests(b: *std.Build, config: Configuration, libraries: Libraries, fixtures: Fixtures, cli: *std.Build.Step.Compile, editors: EditorTools) void {
    const native = libraries.native;
    const huak = libraries.huak;
    const sample = fixtures.sample;
    const drawing = fixtures.drawing;
    const fixture_options = b.addOptions();
    fixture_options.addOptionPathUntracked("library_path", config.typst.library);
    fixture_options.addOptionPath("incompatible_path", fixture(b, config, "incompatible", true).getEmittedBin());
    fixture_options.addOptionPath("incomplete_path", fixture(b, config, "incomplete", false).getEmittedBin());
    const loader_options: Import = .{ .name = "test_options", .module = fixture_options.createModule() };
    const test_options: Import = .{ .name = "test_options", .module = libraries.options.module };
    const cli_options = b.addOptions();
    cli_options.addOptionPath("executable_path", cli.getEmittedBin());
    cli_options.addOptionPathUntracked("library_path", config.typst.library);
    cli_options.addOption([]const u8, "huak_version", @import("../build.zig.zon").version);
    const all_tests = b.step("test", "Run all unit and native integration tests");
    const language_tests = b.step("test-language", "Test the script language and native rendering");
    const animation_tests = b.step("test-animation", "Test animation encoding and native rendering");
    const region_tests = b.step("test-region-geometry", "Test curve regions with their drawing dependencies");
    const suites = [_]struct { source: []const u8, name: []const u8, imports: []const Import, native: bool = true, group: ?*std.Build.Step = null }{
        .{ .source = "tests/cli.zig", .name = "test-cli", .imports = &.{ native, .{ .name = "test_options", .module = cli_options.createModule() }, .{ .name = "xml_parser", .module = libraries.xml } }, .group = language_tests },
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
        .{ .source = "build/rust.zig", .name = "test-rust-targets", .imports = &.{}, .native = false },
        .{ .source = "cli/options.zig", .name = "test-cli-options", .imports = &.{libraries.clap}, .native = false },
        .{ .source = "bench/regions_compare.zig", .name = "test-region-benchmark", .imports = &.{libraries.clap}, .native = false },
        .{ .source = "tests/region/regressions.zig", .name = "test-region", .imports = &.{fixtures.regions}, .native = false },
        .{ .source = "tests/region.zig", .name = "test-region-operations", .imports = &.{libraries.drawing}, .native = false },
        .{ .source = "src/drawing/root.zig", .name = "test-geometry", .imports = &.{}, .native = false, .group = region_tests },
    };
    inline for (suites) |suite| {
        const root = module(b, config.target, config.optimize, suite.source, suite.imports);
        const command = b.addRunArtifact(b.addTest(.{ .root_module = root, .use_llvm = config.use_llvm }));
        if (suite.native) config.typst.loadIn(command);
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
    const editor_options = b.addOptions();
    editor_options.addOptionPathUntracked("library_path", config.typst.library);
    editor_options.addOptionPath("formatter_path", editors.formatter.getEmittedBin());
    editor_options.addOptionPath("language_server_path", editors.language_server.getEmittedBin());
    const editor_tests = b.addRunArtifact(b.addTest(.{ .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "tests/editor_tools.zig", &.{ libraries.tooling, libraries.native, .{ .name = "test_options", .module = editor_options.createModule() } }) }));
    config.typst.loadIn(editor_tests);
    all_tests.dependOn(&editor_tests.step);
    const tools_tests = b.step("test-tools", "Test formatter and language server processes");
    tools_tests.dependOn(&editor_tests.step);
    // The editor files against what the language and the tools define.
    const command_line: Import = .{ .name = "cli_options", .module = module(b, config.target, config.optimize, "cli/options.zig", &.{libraries.clap}) };
    const contract = module(b, config.target, config.optimize, "tests/editor_contract.zig", &.{ libraries.huak, command_line });
    contract.addAnonymousImport("editor_grammar", .{ .root_source_file = b.path(editor_grammar) });
    contract.addAnonymousImport("editor_configuration", .{ .root_source_file = b.path(editor_configuration) });
    for ([_][2][]const u8{ .{ "extension_main", "extension.js" }, .{ "extension_render", "render.js" }, .{ "extension_preview", "preview.js" }, .{ "extension_watch", "watch.js" }, .{ "extension_outputs", "outputs.js" } }) |file|
        contract.addAnonymousImport(file[0], .{ .root_source_file = b.path(b.fmt("editors/vscode/src/{s}", .{file[1]})) });
    const contract_tests = b.addRunArtifact(b.addTest(.{ .use_llvm = config.use_llvm, .root_module = contract }));
    tools_tests.dependOn(&contract_tests.step);
    all_tests.dependOn(&contract_tests.step);
    const hygiene = module(b, config.target, config.optimize, "tests/repo_hygiene.zig", &.{});
    hygiene.addAnonymousImport("space_projection_h", .{ .root_source_file = b.path("src/drawing/space/projection.h") });
    hygiene.addAnonymousImport("space_readme", .{ .root_source_file = b.path("src/drawing/space/README.md") });
    const hygiene_tests = b.addRunArtifact(b.addTest(.{ .use_llvm = config.use_llvm, .root_module = hygiene }));
    hygiene_tests.has_side_effects = true;
    all_tests.dependOn(&hygiene_tests.step);
    b.step("test-hygiene", "Run repository hygiene contract tests").dependOn(&hygiene_tests.step);
    const tool_units = b.addRunArtifact(b.addTest(.{ .use_llvm = config.use_llvm, .root_module = libraries.tooling.module }));
    tools_tests.dependOn(&tool_units.step);
    all_tests.dependOn(&tool_units.step);
    _ = program(b, config, .{ .name = "animation-references", .source = "tests/animation/references.zig", .step = "verify-animation", .description = "Generate native animation reference fixtures", .imports = &.{ libraries.native, libraries.huak, fixtures.animation, libraries.options } });
}

pub fn addSpaceTests(b: *std.Build, config: Configuration, libraries: Libraries, cli: *std.Build.Step.Compile, backend: space_build.Backend, include_in_suite: bool) void {
    const space = b.step("test-space", "Test native OCCT modeling and projected visibility in SVG and PDF");
    if (include_in_suite) b.top_level_steps.get("test").?.step.dependOn(space);
    space.dependOn(backend.check);
    // Smooth light against exact light, through the built library.
    const shading = b.addRunArtifact(b.addExecutable(.{ .name = "space-shading", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "tests/space_shading.zig", &.{ libraries.huak, libraries.space_c }) }));
    shading.addFileArg2(backend.library, .{});
    shading.step.dependOn(backend.build);
    shading.has_side_effects = true;
    space.dependOn(&shading.step);
    // The CLI and the adapter laid out in the cache as they are installed, so
    // the CLI finds the adapter through its rpath.
    const tree = b.addWriteFiles();
    tree.step.dependOn(backend.build);
    const huak = tree.addCopyFile(cli.getEmittedBin(), b.fmt("bin/{s}", .{cli.out_filename}));
    _ = tree.addCopyFile(backend.library, b.fmt("lib/{s}", .{backend.name}));
    for (space_contracts.names) |name| {
        const projection = std.Build.Step.Run.create(b, b.fmt("run {s}", .{cli.name}));
        projection.addFileArg2(huak, .{});
        projection.addArg("run");
        projection.addFileArg(b.path(b.fmt("tests/fixtures/space/{s}.huak", .{name})));
        projection.addArg("--libtypst");
        projection.addFileArg(config.typst.library);
        config.typst.loadIn(projection);
        for ([_][]const u8{ "svg", "pdf" }) |extension| {
            projection.addArg("--output");
            const output = projection.addOutputFileArg2(b.fmt("{s}.{s}", .{ name, extension }), .{});
            // The colors the tones fixture draws are read from its SVG.
            if (std.mem.eql(u8, name, "tones") and std.mem.eql(u8, extension, "svg")) {
                const colors = b.addRunArtifact(b.addExecutable(.{ .name = "space-tones", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "tests/space_tones.zig", &.{}) }));
                colors.addFileArg2(output, .{});
                space.dependOn(&colors.step);
            }
        }
        // Loading the adapter and its OCCT dependencies as installed is part of the test.
        projection.has_side_effects = true;
        space.dependOn(&projection.step);
    }
}

fn fixture(b: *std.Build, config: Configuration, name: []const u8, incompatible: bool) *std.Build.Step.Compile {
    const root = b.createModule(.{ .target = config.target, .optimize = .Debug, .link_libc = true });
    const headers = b.addWriteFiles();
    const header = headers.addCopyFile(b.path("libtypst/include/libtypst.h"), "libtypst.h");
    root.addIncludePath(header.dirname());
    root.addCSourceFile(.{ .file = b.path("tests/fixtures/typst_loader.c"), .flags = &.{ "-std=c11", if (incompatible) "-DTYPST_TEST_INCOMPATIBLE=1" else "-DTYPST_TEST_INCOMPATIBLE=0" } });
    return b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = root, .use_llvm = config.use_llvm });
}
