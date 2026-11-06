pub const names = [_][]const u8{ "visibility", "modeling", "lighting" };

pub fn source(comptime name: []const u8) []const u8 {
    return @embedFile(name ++ ".huak");
}
