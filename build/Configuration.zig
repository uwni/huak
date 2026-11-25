//! The desktop build settings every step receives.
const std = @import("std");
const rust = @import("rust.zig");
const Configuration = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.Optimize,
typst: rust.Libtypst,
use_llvm: ?bool
