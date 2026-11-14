//! Typst itself determines the boundaries of embedded [] and {} blocks.
const std = @import("std");
const api = @import("library.zig");
const binding = @import("typst_binding");
const c = binding.c;

pub fn sourceBlock(library: *api.Library, source: []const u8) api.Error!usize {
    // A block must end at an ASCII delimiter. Limit the native parser's
    // input to a growing prefix; only Typst decides whether it is closed.
    // Each new window is scanned once, including for a single long block.
    var start: usize = 0;
    var limit: usize = @min(128, source.len);
    while (true) {
        const end: ?usize = if (limit == source.len) limit else if (std.mem.lastIndexOfAny(u8, source[start..limit], "]}")) |index| start + index + 1 else null;
        if (end) |count| {
            var length: usize = 0;
            var report: ?*c.TypstDiagnostics = null;
            defer library.functions.diagnostics_release(report);
            const input = source[0..count];
            const result = library.functions.source_block(binding.str(input), &length, &report);
            if (result != c.TYPST_COMPILE_FAILED or limit == source.len) {
                try library.checkDiagnosed(result, report, &.{.{ .name = "source", .text = input }});
                if (length > count) return error.InvalidResult;
                return length;
            }
        }
        start = limit;
        limit = @min(source.len, limit *| 2);
    }
}

/// Where `source`, parsed in `syntax` mode, reads members of `name`, copied into
/// `allocator`. The native parser finds them; no Typst syntax is read here.
pub fn memberUses(library: *api.Library, allocator: std.mem.Allocator, source: []const u8, syntax: api.Syntax, name: []const u8) api.Error!api.MemberUses {
    if (!try library.supports(c.TYPST_CAP_MEMBER_USES)) {
        try library.setError("libtypst does not report member uses");
        return error.Unsupported;
    }
    var handle: ?*c.TypstMemberUses = null;
    defer library.functions.member_uses_release(handle);
    var report: ?*c.TypstDiagnostics = null;
    defer library.functions.diagnostics_release(report);
    const mode: u32 = switch (syntax) {
        .markup => c.TYPST_SYNTAX_MARKUP,
        .code => c.TYPST_SYNTAX_CODE,
        .math => c.TYPST_SYNTAX_MATH,
    };
    try library.checkDiagnosed(library.functions.source_member_uses(binding.str(source), mode, binding.str(name), &handle, &report), report, &.{.{ .name = "source", .text = source }});
    var view: c.TypstMemberUseView = undefined;
    try library.check(library.functions.member_uses_view(handle, &view), null);
    const records = if (view.use_count == 0) &[_]c.TypstMemberUse{} else view.uses[0..view.use_count];
    const uses = try allocator.alloc(api.MemberUse, records.len);
    var copied: usize = 0;
    errdefer {
        for (uses[0..copied]) |use| allocator.free(use.member);
        allocator.free(uses);
    }
    for (records, uses) |record, *use| {
        if (record.start > record.end or record.end > source.len) return error.InvalidResult;
        use.* = .{ .member = try allocator.dupe(u8, record.member.data[0..record.member.len]), .start = record.start, .end = record.end };
        copied += 1;
    }
    return .{ .uses = uses, .rebound = view.flags & c.TYPST_MEMBER_USES_REBOUND != 0, .whole = view.flags & c.TYPST_MEMBER_USES_WHOLE != 0 };
}
