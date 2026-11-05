//! Synchronous point-function bridge. Curve reconstruction stays in drawing;
//! script execution, limits and diagnostics stay in the existing VM.
const geometry = @import("../../drawing/geometry.zig");
const Machine = @import("../Machine.zig");
const types = @import("../types.zig");

const Mapping = @This();

machine: *Machine,
function: types.Value,
context: ?types.Value,

pub fn point(self: Mapping, input: geometry.Point) !geometry.Point {
    const args = [_]types.Value{ .{ .pair = types.Pair.fromPoint(input) }, self.context orelse .unit };
    const result = try self.machine.invokeFunction(self.function, args[0..if (self.context != null) @as(usize, 2) else 1]);
    if (result != .pair) return error.PointMappingMustReturnPair;
    return result.pair.nativePoint();
}
