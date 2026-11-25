pub const names = [_][]const u8{ "visibility", "modeling", "lighting", "smooth", "tones", "fields", "poles", "apex" };

pub fn source(comptime name: []const u8) []const u8 {
    return @embedFile(name ++ ".huak");
}
