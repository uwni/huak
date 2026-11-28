//! Verifies single-opaque Type 7 PDF meshes with zero /SMask on translucent
//! torus shading (`space.shaded` and `space.colored(..., light: true)`),
//! both flattened (`translucent: false`) and grouped (`translucent: true`).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) {
        std.debug.print("usage: {s} SHADED_FLAT SHADED_TRANS COLORED_FLAT COLORED_TRANS\n", .{args[0]});
        return error.InvalidArguments;
    }
    const cases = [_]struct { name: []const u8, path: []const u8, expect_group: bool }{
        .{ .name = "shaded flat", .path = args[1], .expect_group = false },
        .{ .name = "shaded translucent", .path = args[2], .expect_group = true },
        .{ .name = "colored+light flat", .path = args[3], .expect_group = false },
        .{ .name = "colored+light translucent", .path = args[4], .expect_group = true },
    };
    for (cases) |case| {
        const pdf = try std.Io.Dir.cwd().readFileAlloc(init.io, case.path, a, .limited(64 * 1024 * 1024));
        const shadings = std.mem.count(u8, pdf, "/ShadingType 7");
        const smasks = std.mem.count(u8, pdf, "/SMask");
        const has_ca = std.mem.find(u8, pdf, "/ca 0.6") != null;
        if (shadings != 1 or smasks != 0 or has_ca != case.expect_group) {
            std.debug.print("{s}: ShadingType7={d}, SMask={d}, has /ca 0.6={} (expected 1, 0, {})\n", .{
                case.name, shadings, smasks, has_ca, case.expect_group,
            });
            return error.UnexpectedPdfStructure;
        }
    }
}
