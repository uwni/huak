# Region reference contracts

Production regions use the [pure Zig Paper.js 0.16.0 port](../../src/drawing/region/boolean/).
The former C++ reference programs were a migration oracle; their geometry
contracts continue to execute through Zig tests without linking that reference.
Their C++ container APIs are not Huak APIs.

The [Skia-derived PathOps intersection code](../../src/drawing/region/pathops/README.md)
still serves `path.crossings`, with its original attribution and numeric tests.
Its implementation-specific checks are not evidence that the current region
Boolean kernel has passed acceptance; the public region tests exercise the new
kernel directly.

| Original reference | Continuing Zig checks |
| --- | --- |
| `native.cpp` | `reference.zig`: all four fill rules and Boolean operations, identical/reversed rectangles and cubics, winding cancellation, self-crossing lobes, signed outer/hole/island areas, concave and overlapping containment bounds, original glyph O boundary cut, retained cubics, fine holes at spans 1e5/1e6/1e8 |
| `numerics.cpp` | `pathops/numeric.zig`: the same strict ULP endpoints, signed zero, subnormal, extreme-scale and nonfinite rules; `curve.zig`: radii 6/10 coordinate-root bounds and nearest-representable endpoint root; `roots.zig`: the original near-coincident polynomial |
| `lines.cpp` | `pathops/intersections.zig`: all three captured near-parallel pairs, scales 2^-80/1/2^80 and all four reversals, exact midpoint, original 32-epsilon coordinate/parameter bounds; `numeric.zig`: DD subtraction and FMA product tails; `curve.zig`: captured line evaluation matches C++ coordinate bits before coincidence classification |
| `containers.cpp` | `reference.zig`: public Path preserves binary64 small features, controls, owned reversal and explicit close semantics; former PathOps writer and reducer checks describe the retired Boolean implementation's internal containers |

`reference.zig` retains the independent three-point Gauss area integral from
`native.cpp`. Its absolute threshold is 1e-9, except the original basic rectangle
checks remain 1e-10. The glyph fixture keeps its exact f64 coordinates, two
positive components, at least nine cubics and all five 0.0002-square probes with
their original 1e-9 area threshold. These checks exercise the public
`core.region.combine` API and own ordinary Huak Paths.

C++ `sizeof(SkScalar)`/`sizeof(SkPoint)` checks, raw-versus-legacy iterator record
arity, synthetic closing-line records and the adapter's rational-conic storage
are specific to the retired reference's internal containers. Huak's public Path
stores move/line/cubic/close segments, and never exposed that conic container or
its weight API. Recreating those C++ interfaces in Zig would not preserve an
additional public drawing feature. Curves continue to keep binary64 control
points; closing edges remain geometrically present. Public reference, ownership
and allocation-failure tests cover these retained semantics independently of
the retired writer's internal representation.

The fixed 21-case, 84-operation coverage corpus remains separate in
`regressions.zig` and `tests/fixtures/regions`. This mapping does not replace its
original assertions, any integration tests, or the full acceptance run.
Current performance acceptance is separate and has not been completed; historical
candidate timings do not measure the current native kernel.
