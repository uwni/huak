const std = @import("std");
const zlinter = @import("zlinter");

pub fn addLint(b: *std.Build) void {
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addPaths(.{
            .include_files = &.{b.path("build.zig")},
            .include_dirs = &.{
                b.path("build"),
                b.path("src"),
                b.path("cli"),
                b.path("apps"),
                b.path("stdlib"),
                b.path("examples"),
                b.path("bench"),
                b.path("tests"),
                b.path("packages/plot/bench"),
                b.path("packages/plot/tests"),
                b.path("packages/nodegraph/tests"),
                b.path("packages/arrows/tests"),
            },
        });
        builder.addRule(.{ .builtin = .field_naming }, .{
            .error_field_min_len = .off,
            .error_field_max_len = .off,
            .enum_field_min_len = .off,
            .enum_field_max_len = .off,
            .struct_field_min_len = .off,
            .struct_field_max_len = .off,
            .union_field_min_len = .off,
            .union_field_max_len = .off,
        });
        builder.addRule(.{ .builtin = .declaration_naming }, .{
            .exclude_export = true,
            // zlinter classifies fieldless structs (including zero-sized HashMap
            // contexts and local callback helpers) as namespaces (#149), and
            // falls back to const_decl whenever a cross-module, C, or comptime
            // type/function cannot be resolved.
            .const_decl = .off,
            .decl_that_is_namespace = .off,
            .decl_name_min_len = .off,
            .decl_name_max_len = .off,
        });
        builder.addRule(.{ .builtin = .function_naming }, .{
            .exclude_export = true,
        });
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        break :step builder.build();
    });
}
