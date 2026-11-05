//! Source-preserving SVG events over the mature zig-xml pull reader.
//! XML grammar, namespaces, entities and attributes are parsed by zig-xml.
//! This adapter extracts raw source spans and enforces static SVG policy;
//! it never reserializes glyph definitions or implements XML tokenization.
const std = @import("std");
const parser = @import("xml_parser");
pub const Error = std.mem.Allocator.Error || error{ InvalidSvg, UnsupportedSvg };
const Ids = std.StringHashMap(void);

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,

    pub fn nameStart(attribute: Attribute, svg: []const u8) usize {
        return offset(svg, attribute.name);
    }

    pub fn valueEnd(attribute: Attribute, svg: []const u8) usize {
        return offset(svg, attribute.value) + attribute.value.len;
    }
};
pub const Tag = struct {
    start: usize,
    end: usize,
    name: []const u8,
    closing: bool,
    self_closing: bool,
};

/// Owns the reader's working storage and global ID index, never the input SVG.
/// Tags and raw attribute slices borrow the input. Query attributes immediately
/// after next returns an opening tag; drain next to null for full validation.
pub const Cursor = struct {
    source: parser.Reader.Static,
    ids: Ids,
    has_root: bool = false,
    empty_end: bool = false,

    pub fn init(allocator: std.mem.Allocator, svg: []const u8) Cursor {
        return .{ .source = .init(allocator, svg, .{}), .ids = Ids.init(allocator) };
    }

    pub fn deinit(self: *Cursor) void {
        self.ids.deinit();
        self.source.deinit();
        self.* = undefined;
    }

    pub fn attributeCount(self: *const Cursor) usize {
        return self.source.interface.attributeCount();
    }

    pub fn attribute(self: *const Cursor, index: usize) Attribute {
        return .{
            .name = self.source.interface.attributeName(index),
            .value = self.source.interface.attributeValueRaw(index),
        };
    }

    pub fn next(self: *Cursor) Error!?Tag {
        const reader = &self.source.interface;
        const svg = self.source.data;
        while (true) {
            const node = reader.read() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadFailed => return error.InvalidSvg, // Static reader cannot perform I/O.
                error.MalformedXml => return switch (reader.errorCode()) {
                    .doctype_unsupported, .pi_target_disallowed => error.UnsupportedSvg,
                    else => error.InvalidSvg,
                },
            };
            switch (node) {
                .eof => {
                    if (!self.has_root) return error.InvalidSvg;
                    return null;
                },
                .xml_declaration, .comment, .text, .cdata, .character_reference, .entity_reference => continue,
                .pi => return error.UnsupportedSvg,
                .element_start => {
                    const name = reader.elementName();
                    const start = offset(svg, name) - 1;
                    // Static.pos is the reader window's source offset; the
                    // interface position is relative to that same window.
                    const end = self.source.pos + reader.pos;
                    const self_closing = end >= 2 and svg[end - 2] == '/';
                    const local = reader.elementNameNs().local;
                    for ([_][]const u8{ "script", "style", "animate", "animateTransform", "animateMotion", "animateColor", "set" }) |unsupported| {
                        if (std.mem.eql(u8, local, unsupported)) return error.UnsupportedSvg;
                    }
                    if (!self.has_root) {
                        if (!std.mem.eql(u8, name, "svg")) return error.InvalidSvg;
                        const ns = reader.elementNameNs().ns;
                        if (ns.len != 0 and !std.mem.eql(u8, ns, "http://www.w3.org/2000/svg")) return error.UnsupportedSvg;
                    }
                    for (0..self.attributeCount()) |index| {
                        const attr = self.attribute(index);
                        if (std.mem.eql(u8, attr.name, "id")) {
                            if (!resourceId(attr.value)) return error.UnsupportedSvg;
                            const entry = try self.ids.getOrPut(attr.value);
                            if (entry.found_existing) return error.InvalidSvg;
                        }
                    }
                    self.has_root = true;
                    // zig-xml also emits element_end for an empty element;
                    // the cursor returns its one physical source tag.
                    if (self_closing) self.empty_end = true;
                    return .{ .start = start, .end = end, .name = name, .closing = false, .self_closing = self_closing };
                },
                .element_end => {
                    if (self.empty_end) {
                        self.empty_end = false;
                        continue;
                    }
                    const name = reader.elementName();
                    return .{ .start = offset(svg, name) - 2, .end = self.source.pos + reader.pos, .name = name, .closing = true, .self_closing = false };
                },
            }
        }
    }
};

fn offset(input: []const u8, value: []const u8) usize {
    return @intFromPtr(value.ptr) - @intFromPtr(input.ptr);
}

// Wrapper ID collision checks use unescaped static resource IDs. This is an
// animation adapter restriction, not XML name or attribute parsing.
fn resourceId(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != ':' and c != '.' and c < 0x80) return false;
    return true;
}

fn consume(allocator: std.mem.Allocator, input: []const u8) Error!void {
    var cursor = Cursor.init(allocator, input);
    defer cursor.deinit();
    while (try cursor.next()) |_| {}
}

test "static SVG validation delegates XML grammar and namespaces to zig-xml" {
    for ([_][]const u8{
        "",                                                       "<svg>",              "<svg><g/>",
        "<svg a='1' a='2'/>",                                     "<svg><g></svg>",     "<svg/><svg/>",
        "before<svg/>",                                           "<svg>after</wrong>", "<svg a='<'/>",
        "<svg>&undefined;</svg>",                                 "<svg>&#0;</svg>",    "<svg><1bad/></svg>",
        "<svg><!-- a -- b --></svg>",                             "<svg a='1'b='2'/>",  "<svg><x:g/></svg>",
        "<svg xmlns:a='urn:x' xmlns:b='urn:x' a:x='1' b:x='2'/>",
    }) |input| try std.testing.expectError(error.InvalidSvg, consume(std.testing.allocator, input));
    for ([_][]const u8{
        "<svg xmlns='other'/>",  "<!DOCTYPE svg><svg/>", "<?xml-stylesheet href='x'?><svg/>",
        "<svg><?work x?></svg>", "<svg><style/></svg>",  "<svg><animate/></svg>",
    }) |input| try std.testing.expectError(error.UnsupportedSvg, consume(std.testing.allocator, input));
}

test "source offsets preserve declarations comments whitespace quotes entities CDATA and shared definitions" {
    const input = "\xef\xbb\xbf<?xml version='1.0'?>\n<!--before--><svg xmlns='http://www.w3.org/2000/svg'>\n<defs><path id='shape' d=\"M0 0L1 1\"/></defs><g data-note='A&amp;B'><!--keep--><![CDATA[<>]]><use href='#shape'/></g></svg>\n<!--after-->";
    var root: Tag = undefined;
    var close: Tag = undefined;
    var group: Tag = undefined;
    var group_attribute: Attribute = undefined;
    {
        var cursor = Cursor.init(std.testing.allocator, input);
        defer cursor.deinit();
        var index: usize = 0;
        while (try cursor.next()) |tag| : (index += 1) {
            if (index == 0) root = tag;
            close = tag;
            try std.testing.expectEqual(@as(u8, '<'), input[tag.start]);
            try std.testing.expectEqual(@as(u8, '>'), input[tag.end - 1]);
            if (tag.closing) continue;
            for (0..cursor.attributeCount()) |attribute_index| {
                const attr = cursor.attribute(attribute_index);
                try std.testing.expectEqualStrings(attr.name, input[attr.nameStart(input)..][0..attr.name.len]);
                try std.testing.expectEqualStrings(attr.value, input[offset(input, attr.value)..attr.valueEnd(input)]);
            }
            if (index == 4) {
                group = tag;
                group_attribute = cursor.attribute(0);
            }
        }
        try std.testing.expectEqual(@as(usize, 8), index);
        try std.testing.expect(cursor.ids.contains("shape"));
    }
    // Static raw slices belong to input, including after cursor cleanup.
    try std.testing.expectEqualStrings("<svg xmlns='http://www.w3.org/2000/svg'>", input[root.start..root.end]);
    try std.testing.expectEqualStrings("</svg>", input[close.start..close.end]);
    try std.testing.expectEqualStrings("g", group.name);
    try std.testing.expectEqualStrings("A&amp;B", group_attribute.value);
}

test "ID validation retains source order relative to unsupported elements" {
    try std.testing.expectError(error.InvalidSvg, consume(std.testing.allocator, "<svg><path id='same'/><g id='same'/><script/></svg>"));
    try std.testing.expectError(error.UnsupportedSvg, consume(std.testing.allocator, "<svg><path id='same'/><script/><g id='same'/></svg>"));
    try std.testing.expectError(error.UnsupportedSvg, consume(std.testing.allocator, "<svg><path id='A&amp;B'/></svg>"));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><defs><path id='a'/></defs><g a='x&amp;y'><use href='#a'/></g></svg>";
    var cursor = Cursor.init(allocator, input);
    defer cursor.deinit();
    var count: usize = 0;
    while (try cursor.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expect(cursor.ids.contains("a"));
}
test "reader and source index clean up on every allocation failure" {
    // Force growth to allocate so heap-dependent in-place resizes cannot vary
    // the allocation count between fault-injection runs.
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationCase, .{});
}
