//! Desktop executables with their rpaths and run steps: the CLI, the editor tools and grammar, and the examples.
const std = @import("std");
const Import = std.Build.Module.Import;
const Configuration = @import("Configuration.zig");
const module_graph = @import("modules.zig");
const module = module_graph.module;
const Libraries = module_graph.Libraries;
const Fixtures = module_graph.Fixtures;

pub const EditorTools = struct { formatter: *std.Build.Step.Compile, language_server: *std.Build.Step.Compile };

pub const Program = struct { name: []const u8, source: []const u8, step: []const u8, description: []const u8, imports: []const Import };

/// The VS Code grammar and language configuration, which the Playground copies.
pub const editor_grammar = "editors/vscode/syntaxes/huak.tmLanguage.json";

pub const editor_configuration = "editors/vscode/language-configuration.json";

pub fn desktopExecutable(b: *std.Build, config: Configuration, name: []const u8, source: []const u8, imports: []const Import) *std.Build.Step.Compile {
    const app = b.addExecutable(.{ .name = name, .linkage = .dynamic, .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, source, imports) });
    const origin = if (config.target.result.os.tag == .macos) "@executable_path" else "$ORIGIN";
    app.root_module.addRPathSpecial(b.fmt("{s}/../lib", .{origin}));
    app.root_module.addRPathSpecial(origin);
    return app;
}

pub fn addCli(b: *std.Build, config: Configuration, libraries: Libraries, desktop: Import, tools: *std.Build.Step) *std.Build.Step.InstallArtifact {
    const app = desktopExecutable(b, config, "huak", "cli/main.zig", &.{ libraries.huak, libraries.native, desktop, libraries.clap });
    const install = b.addInstallArtifact(app, .{});
    tools.dependOn(&install.step);
    return install;
}

pub fn runInstalled(b: *std.Build, config: Configuration, app: *std.Build.Step.InstallArtifact, backend: ?*std.Build.Step) *std.Build.Step.Run {
    const command = std.Build.Step.Run.create(b, b.fmt("run {s}", .{app.artifact.name}));
    command.addFileArg2(b.graph.path(.install_bin, app.artifact.name), .{});
    command.step.dependOn(&app.step);
    command.step.dependOn(config.typst.install);
    if (backend) |install| command.step.dependOn(install);
    return command;
}

pub fn addEditorTools(b: *std.Build, config: Configuration, libraries: Libraries, desktop: Import, tools: *std.Build.Step) EditorTools {
    const imports = &.{ libraries.tooling, libraries.native, desktop, libraries.clap };
    const formatter = desktopExecutable(b, config, "huak-fmt", "apps/formatter/main.zig", imports);
    const language_server = desktopExecutable(b, config, "huak-lsp", "apps/language_server/main.zig", imports);
    const install_formatter = b.addInstallArtifact(formatter, .{});
    const install_server = b.addInstallArtifact(language_server, .{});
    tools.dependOn(&install_formatter.step);
    tools.dependOn(&install_server.step);
    b.step("formatter", "Build and install the standalone formatter").dependOn(&install_formatter.step);
    b.step("language-server", "Build and install the standalone language server").dependOn(&install_server.step);
    // The editor grammars take the language's words and patterns from it.
    const grammar = b.addRunArtifact(b.addExecutable(.{ .name = "editor-grammar", .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, "apps/editor_grammar/main.zig", &.{libraries.tooling}) }));
    grammar.addFileArg(b.path(editor_grammar));
    grammar.addFileArg(b.path(editor_configuration));
    grammar.has_side_effects = true;
    b.step("editor-grammar", "Write the language's words and patterns into the editor grammars").dependOn(&grammar.step);
    return .{ .formatter = formatter, .language_server = language_server };
}

pub fn addExamples(b: *std.Build, config: Configuration, libraries: Libraries, fixtures: Fixtures, desktop: Import) void {
    const install = b.step("examples", "Build and install programmatic examples");
    install.dependOn(config.typst.install);
    const programs = [_]Program{
        .{ .name = "huak-drawing", .source = "examples/drawing.zig", .step = "run-drawing", .description = "Render a native mathematical picture", .imports = &.{ libraries.native, fixtures.drawing_workflow, desktop } },
        .{ .name = "huak-typst", .source = "examples/typst.zig", .step = "run-typst", .description = "Compile an in-memory Typst document", .imports = &.{ libraries.native, fixtures.sample, fixtures.typst_workflow, desktop } },
        .{ .name = "huak-outlines", .source = "examples/outlines.zig", .step = "run-outlines", .description = "Edit laid-out glyph outlines", .imports = &.{ libraries.native, libraries.huak, desktop } },
        .{ .name = "huak-animation", .source = "examples/animation.zig", .step = "run-animation", .description = "Export continuous SVG animation", .imports = &.{ libraries.native, libraries.huak, fixtures.animation, desktop } },
    };
    for (programs) |spec| {
        const artifact = b.addInstallArtifact(desktopExecutable(b, config, spec.name, spec.source, spec.imports), .{});
        install.dependOn(&artifact.step);
        const run = runInstalled(b, config, artifact, null);
        run.addPassthruArgs();
        b.step(spec.step, spec.description).dependOn(&run.step);
    }
}

pub fn program(b: *std.Build, config: Configuration, spec: Program) *std.Build.Step.Compile {
    const app = b.addExecutable(.{ .name = spec.name, .use_llvm = config.use_llvm, .root_module = module(b, config.target, config.optimize, spec.source, spec.imports) });
    const command = b.addRunArtifact(app);
    for (spec.imports) |dependency| if (std.mem.eql(u8, dependency.name, "host_options")) {
        config.typst.loadIn(command);
        break;
    };
    command.addPassthruArgs();
    b.step(spec.step, spec.description).dependOn(&command.step);
    return app;
}
