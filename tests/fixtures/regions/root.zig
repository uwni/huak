//! Shared production-region fixture adapter. Source geometry and the bounded
//! independent coverage oracle remain the original comparison corpus.
const std = @import("std");
pub const drawing = @import("drawing");
pub const source = @import("cases.zig");
pub const validation = @import("validation.zig");
pub const cases = source.cases;
pub const Case = source.Case;
pub const Inputs = source.Inputs;
pub const Operation = source.Operation;
pub const input = source.input;

pub fn options(case: Case) drawing.region.Options {
    return .{
        .tolerance = case.tolerance,
        .fill_rule = if (case.fill == 1) .evenodd else .nonzero,
        .max_segments = if (case.expanded_budget) 1048576 else 65536,
        .max_vertices = if (case.expanded_budget) 4194304 else 1048576,
    };
}

pub fn operation(value: Operation) drawing.region.Operation {
    return switch (value) {
        .difference => .difference,
        .intersection => .intersect,
        .unite => .unite,
        .xor => .xor,
    };
}

/// Check the original-case operation against unchanged source probes. Other
/// operations use the existing source-curve reference at the same locations.
pub fn verify(allocator: std.mem.Allocator, data: Inputs, case: Case, actual: drawing.Path, selected: Operation) !validation.Counts {
    const elements = try source.elements(allocator, actual);
    defer allocator.free(elements);
    const report = try validation.verifyOperation(allocator, data, case, elements, 0, selected);
    if (report.grid_checked == 0 or report.grid_mismatch != 0 or report.special_mismatch != 0 or report.special_checked != data.probes.len) {
        std.debug.print("region fixture failed: {s} {s}; tolerance={e}; grid={d}/{d} probes={d}/{d}\n", .{ case.name, @tagName(selected), case.tolerance, report.grid_mismatch, report.grid_checked, report.special_mismatch, report.special_checked });
        return error.RegionCoverageMismatch;
    }
    const counts = validation.counts(elements);
    if (case.shape == .unchanged and selected == case.operation) {
        if (counts.cubics < 4 or try validation.preservation(allocator, data.ae, elements) > case.tolerance * 0.25) return error.RegionCurvePreservationMismatch;
    }
    if ((case.shape == .coincident or case.shape == .coincident_reversed) and (selected == .difference or selected == .xor) and elements.len != 0) return error.RegionCoincidenceMismatch;
    return counts;
}
