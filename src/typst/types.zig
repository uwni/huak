//! Huak's in-memory typography requests and configuration.
//! These are host values, not records exported by the libtypst C ABI.
const std = @import("std");
const c = @import("typst_binding").c;

pub const FontSource = struct { data: []const u8 };
pub const Input = struct { key: []const u8, value: []const u8 };
pub const EngineOptions = struct {
    font_sources: []const FontSource = &.{},
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
    bindings: []const c.TypstBinding = &.{},
};
pub const Metrics = struct { width: f64, height: f64, baseline: f64 };
