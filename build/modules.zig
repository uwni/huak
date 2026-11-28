//! The module graph: the engine and its bindings, translated C headers, tooling, and the fixtures tests and benchmarks share.
const std = @import("std");
const Translator = @import("translate_c").Translator;
const Import = std.Build.Module.Import;
const Configuration = @import("Configuration.zig");

pub const Modules = struct {
    binding: Import,
    native: Import,
    huak: Import,
    tooling: Import,
    options: Import,
    xml: Import,
    clap: Import,
    drawing: Import,
    workers: Import,
    space_c: Import,
};

pub const Fixtures = struct {
    sample: Import,
    drawing: Import,
    animation: Import,
    drawing_workflow: Import,
    typst_workflow: Import,
    regions: Import,
};

const EngineModules = struct {
    binding: Import,
    native: Import,
    huak: Import,
    workers: Import,
    standard_library: Import,
    csv: Import,
    xml: Import,
    space_c: Import,
};

pub fn engineModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    comptime public: bool,
) EngineModules {
    const loader: Import = .{
        .name = "shared_library",
        .module = b.createModule(.{
            .root_source_file = b.path("src/native/SharedLibrary.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    };
    if (target.result.os.tag != .wasi) {
        const dl: Translator = .init(b.dependency("translate_c", .{}), .{
            .c_source_file = b.path("src/native/dlfcn.h"),
            .target = target,
            .optimize = optimize,
        });
        loader.module.addImport("dlfcn", dl.mod);
    }

    const c_api: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("libtypst/include/libtypst.h"),
        .target = target,
        .optimize = optimize,
    });
    
    const binding = engineModule(b, public, "typst_binding", .{
        .root_source_file = b.path("src/typst/binding.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "typst_c",
                .module = c_api.mod,
            },
        },
    });
    const native = engineModule(b, public, "libtypst", .{
        .root_source_file = b.path("src/typst/library.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ binding, loader },
    });
    const xml: Import = .{
        .name = "xml_parser",
        .module = b.dependency("xml", .{
            .target = target,
            .optimize = optimize,
        }).module("xml"),
    };

    const csv: Import = .{
        .name = "csvzero",
        .module = b.dependency("csvzero", .{
            .target = target,
            .optimize = optimize,
        }).module("csvzero"),
    };

    const standard_library: Import = .{
        .name = "huak_std",
        .module = b.createModule(.{
            .root_source_file = b.path("stdlib/catalog.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };
    const workers: Import = .{
        .name = "workers",
        .module = b.createModule(.{
            .root_source_file = b.path("src/concurrency/Workers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };
    const engine = engineModule(b, public, "huak", .{
        .root_source_file = b.path("src/huak.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            native,
            loader,
            xml,
            standard_library,
            csv,
            workers,
        },
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("../build.zig.zon").version);
    engine.module.addOptions("build_options", build_options);
    const projection: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/drawing/space/projection.h"),
        .target = target,
        .optimize = optimize,
    });
    engine.module.addImport("space_c", projection.mod);
    return .{
        .binding = binding,
        .native = native,
        .huak = engine,
        .workers = workers,
        .standard_library = standard_library,
        .csv = csv,
        .xml = xml,
        .space_c = .{ .name = "space_c", .module = projection.mod },
    };
}

fn engineModule(
    b: *std.Build,
    comptime public: bool,
    name: []const u8,
    options: std.Build.Module.CreateOptions,
) Import {
    return .{
        .name = name,
        .module = if (public) b.addModule(name, options) else b.createModule(options),
    };
}

pub fn addModules(b: *std.Build, config: Configuration) Modules {
    const engine = engineModules(b, config.target, config.optimize, true);
    const clap: Import = .{
        .name = "clap",
        .module = b.dependency("clap", .{
            .target = config.target,
            .optimize = config.optimize,
        }).module("clap"),
    };

    const drawing: Import = .{
        .name = "drawing",
        .module = module(b, config.target, config.optimize, "src/drawing/root.zig", &.{engine.workers}),
    };

    const tooling = b.addModule("huak_tooling", .{
        .root_source_file = b.path("src/tooling.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
        .imports = &.{ engine.standard_library, engine.csv },
    });

    const defaults = b.addOptions();
    defaults.addOptionPathUntracked("library_path", config.typst.library);

    return .{
        .binding = engine.binding,
        .native = engine.native,
        .huak = engine.huak,
        .tooling = .{
            .name = "huak_tooling",
            .module = tooling,
        },
        .options = .{
            .name = "host_options",
            .module = defaults.createModule(),
        },
        .xml = engine.xml,
        .clap = clap,
        .drawing = drawing,
        .workers = engine.workers,
        .space_c = engine.space_c,
    };
}

pub fn fixtureModules(b: *std.Build, config: Configuration, modules: Modules) Fixtures {
    const native = modules.native;
    const huak = modules.huak;
    const sample: Import = .{
        .name = "typst_sample",
        .module = module(b, config.target, config.optimize, "examples/scenes/typst.zig", &.{}),
    };

    const drawing: Import = .{
        .name = "drawing_scene",
        .module = module(b, config.target, config.optimize, "examples/scenes/drawing.zig", &.{ huak, native }),
    };

    const animation: Import = .{
        .name = "animation_scene",
        .module = module(b, config.target, config.optimize, "examples/scenes/animation.zig", &.{ huak, native, drawing }),
    };

    const drawing_workflow: Import = .{
        .name = "drawing_workflow",
        .module = module(b, config.target, config.optimize, "examples/support/drawing.zig", &.{ huak, native, drawing }),
    };

    const typst_workflow: Import = .{
        .name = "typst_workflow",
        .module = module(b, config.target, config.optimize, "examples/support/typst.zig", &.{native}),
    };

    const regions: Import = .{
        .name = "region_fixtures",
        .module = module(b, config.target, config.optimize, "tests/fixtures/regions/root.zig", &.{modules.drawing}),
    };

    return .{
        .sample = sample,
        .drawing = drawing,
        .animation = animation,
        .drawing_workflow = drawing_workflow,
        .typst_workflow = typst_workflow,
        .regions = regions,
    };
}

pub fn module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    source: []const u8,
    imports: []const Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
}
