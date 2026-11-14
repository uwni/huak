//! Huak's in-memory typography requests and configuration.
//! These are host values, not records exported by the libtypst C ABI.
const std = @import("std");
const c = @import("typst_binding").c;
const Module = @import("Module.zig");

pub const FontSource = struct { data: []const u8 };
pub const Input = struct { key: []const u8, value: []const u8 };
pub const EngineOptions = struct {
    font_sources: []const FontSource = &.{},
    /// Directories libtypst scans recursively; their fonts load on first use.
    font_dirs: []const []const u8 = &.{},
    /// Also use the fonts installed on the system, as libtypst discovers them.
    system_fonts: bool = false,
    use_bundled_fonts: bool = true,
    inputs: []const Input = &.{},
};
pub const Syntax = enum { markup, math, code };
pub const Region = struct {
    width: f64 = std.math.inf(f64),
    height: f64 = std.math.inf(f64),
    expand_x: bool = false,
    expand_y: bool = false,

    pub fn valid(self: Region) bool {
        return !std.math.isNan(self.width) and !std.math.isNan(self.height) and
            self.width >= 0 and self.height >= 0 and
            (!self.expand_x or std.math.isFinite(self.width)) and
            (!self.expand_y or std.math.isFinite(self.height));
    }
};
pub const LayoutRequest = struct {
    source: []const u8,
    syntax: Syntax = .markup,
    region: ?Region = null,
    /// Independent Typst code scope applied before evaluating the source.
    preamble: []const u8 = "",
    /// Borrowed native-value trees, copied by the library during the call.
    /// TYPST_VALUE_TEMPLATE inputs index `templates`.
    bindings: []const c.TypstBinding = &.{},
    templates: []const Template = &.{},
    /// Indices of templates applied around the content, outermost first.
    shows: []const usize = &.{},
    /// Evaluated modules the request uses. TYPST_VALUE_MODULE_HANDLE inputs
    /// index them; diagnostics raised inside their functions are located in
    /// the text of the module that raised them, including modules these were
    /// evaluated with.
    modules: []const *const Module = &.{},
    /// Show rules given as values, applied inside `shows`, outermost first.
    show_values: []const c.TypstShowValue = &.{},
};
/// Typst code evaluated like an imported file into a module named after
/// `name`'s file stem; `bindings` are visible to it from an enclosing scope.
/// Names differ from "source", "preamble", the templates' and those of the
/// other modules used in the same request.
pub const ModuleSource = struct {
    code: []const u8,
    name: []const u8,
    /// Its TYPST_VALUE_MODULE_HANDLE inputs index `modules`.
    bindings: []const c.TypstBinding = &.{},
    /// Evaluated modules the bindings refer to. The new module borrows them,
    /// so they outlive it.
    modules: []const *const Module = &.{},
    /// Where the code lies in a larger file that diagnostics name instead.
    origin: ?SourceOrigin = null,
};
/// One place where Typst code reads a member of a name, with the member's byte
/// range in the queried source.
pub const MemberUse = struct { member: []const u8, start: usize, end: usize };
/// The member uses of one name in one source, owned by one allocator.
pub const MemberUses = struct {
    uses: []MemberUse,
    /// The source binds the name itself, so some uses may not refer to the
    /// outer value.
    rebound: bool,
    /// The source also uses the name as a whole value, as in `f(name)`.
    whole: bool,

    pub fn deinit(self: MemberUses, allocator: std.mem.Allocator) void {
        for (self.uses) |use| allocator.free(use.member);
        allocator.free(self.uses);
    }
};
/// Typst code whose value is a function, evaluated for the request in its own
/// scope after its setup. Names differ from "source", "preamble" and each other.
pub const Template = struct {
    code: []const u8,
    name: []const u8,
    setup: []const u8 = "",
    setup_name: []const u8 = "",
    /// Its TYPST_VALUE_TEMPLATE inputs may index only earlier templates.
    bindings: []const c.TypstBinding = &.{},
    /// Where the code lies in a larger file that diagnostics name instead.
    origin: ?SourceOrigin = null,
};
/// A file name and the 0-based line and byte column where some text begins.
pub const SourceOrigin = struct { name: []const u8, line: usize, column: usize };
pub const Metrics = struct { width: f64, height: f64, baseline: f64 };
