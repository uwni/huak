const std = @import("std");

/// Cargo writes explicitly targeted artifacts below a directory named after
/// the Rust target. Only the Cargo step depends on this mapping.
pub fn setTarget(b: *std.Build, cargo: *std.Build.Step.Run, target: std.Target, output: std.Build.LazyPath) std.Build.LazyPath {
    const name = targetName(b.allocator, target) catch @panic("OOM") orelse {
        cargo.step.dependOn(&b.addFail(b.fmt("no Rust target mapping for Zig target {t}-{t}-{t} (CPU {s})", .{ target.cpu.arch, target.os.tag, target.abi, target.cpu.model.name })).step);
        return output;
    };
    cargo.addArgs(&.{ "--target", name });
    return output.path(b, name);
}

fn targetName(allocator: std.mem.Allocator, target: std.Target) !?[]const u8 {
    const arch = target.cpu.arch;
    const abi = target.abi;
    if (target.os.tag == .wasi) return if (arch == .wasm32 and abi == .musl) "wasm32-wasip1" else null;
    if (target.os.tag == .macos) {
        if (abi != .none) return null;
        return switch (arch) {
            .aarch64 => "aarch64-apple-darwin",
            .x86_64 => "x86_64-apple-darwin",
            .x86 => if (target.cpu.has(.x86, .sse2)) "i686-apple-darwin" else null,
            else => null,
        };
    }
    if (target.os.tag != .linux) return null;

    // Rust's platform names encode some ISA baselines in the architecture.
    // Keep the requested C ABI explicit, particularly for ARM and x86 x32.
    const name: []const u8 = switch (arch) {
        .x86 => if (target.cpu.has(.x86, .sse2)) "i686" else if (target.cpu.has(.x86, .cx8)) "i586" else return null,
        .arm => if (target.cpu.has(.arm, .v7a)) "armv7" else if (target.cpu.has(.arm, .has_v6)) "arm" else return null,
        .riscv32, .riscv64 => riscv: {
            if (!target.cpu.hasAll(.riscv, &.{ .i, .m, .a, .f, .d, .c })) return null;
            break :riscv if (arch == .riscv32) "riscv32gc" else "riscv64gc";
        },
        .mips, .mipsel => if (target.cpu.has(.mips, .mips32r6)) switch (abi) {
            .gnu => if (arch == .mips) "mipsisa32r6" else "mipsisa32r6el",
            else => return null,
        } else @tagName(arch),
        .mips64, .mips64el => if (target.cpu.has(.mips, .mips64r6)) switch (abi) {
            .gnuabi64 => if (arch == .mips64) "mipsisa64r6" else "mipsisa64r6el",
            else => return null,
        } else @tagName(arch),
        else => @tagName(arch),
    };
    const common = abi == .gnu or abi == .musl;
    const supported = switch (arch) {
        .aarch64, .aarch64_be, .loongarch64, .mips, .mipsel, .powerpc, .powerpc64, .powerpc64le, .riscv32, .riscv64, .s390x, .x86 => common,
        .x86_64 => common or abi == .gnux32,
        .arm => abi == .gnueabi or abi == .gnueabihf or abi == .musleabi or abi == .musleabihf,
        .armeb => abi == .gnueabi,
        .mips64, .mips64el => abi == .gnuabi64 or abi == .muslabi64,
        .m68k, .sparc, .sparc64 => abi == .gnu,
        .hexagon => abi == .musl,
        else => false,
    };
    if (!supported) return null;
    return try std.fmt.allocPrint(allocator, "{s}-unknown-linux-{t}", .{ name, abi });
}

pub fn installLibtypst(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, name: []const u8, prebuilt: ?[]const u8) *std.Build.Step {
    const step = b.step("libtypst", "Build and install the desktop Typst library and C header");
    const library = if (prebuilt) |path| b.addInstallLibFile(b.graph.cwdRelativePath(path), name) else lib: {
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "--locked", "--lib", "--target-dir", "target" });
        cargo.setCwd(b.path("libtypst"));
        cargo.removeEnvironmentVariable("CARGO_BUILD_TARGET");
        const profile = if (optimize == .debug) "debug" else "release";
        if (optimize != .debug) cargo.addArg("--release");
        var dir = b.path("libtypst/target");
        if (!target.query.isNative()) {
            dir = setTarget(b, cargo, target.result, dir);
        }
        const install = b.addInstallLibFile(dir.path(b, profile).path(b, name), name);
        install.step.dependOn(&cargo.step);
        break :lib install;
    };
    step.dependOn(&library.step);
    step.dependOn(&b.addInstallHeaderFile(b.path("libtypst/include/libtypst.h"), "libtypst.h").step);
    return step;
}

test "Cargo targets retain the Zig architecture, ABI and instruction baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Case = struct { query: std.Target.Query, name: ?[]const u8 };
    const cases = [_]Case{
        .{ .query = .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .gnu }, .name = "i686-unknown-linux-gnu" },
        .{ .query = .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl, .cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium } }, .name = "i586-unknown-linux-musl" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnux32 }, .name = "x86_64-unknown-linux-gnux32" },
        .{ .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf }, .name = "armv7-unknown-linux-musleabihf" },
        .{ .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabi, .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1136j_s } }, .name = "arm-unknown-linux-gnueabi" },
        .{ .query = .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu }, .name = "riscv64gc-unknown-linux-gnu" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "aarch64-apple-darwin" },
        .{ .query = .{ .cpu_arch = .wasm32, .os_tag = .wasi }, .name = "wasm32-wasip1" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .muslx32 }, .name = null },
        .{ .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnu }, .name = null },
    };
    for (cases) |case| {
        const target = try std.zig.system.resolveTargetQuery(std.testing.io, case.query);
        const name = try targetName(arena.allocator(), target);
        if (case.name) |expected| {
            try std.testing.expectEqualStrings(expected, name orelse return error.MissingRustTarget);
        } else try std.testing.expect(name == null);
    }
}
