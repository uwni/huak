# Skia-derived curve queries

This directory retains the binary64 curve and intersection primitives used by
[`path/crossings.zig`](../../path/crossings.zig). Region Boolean operations use
[`../boolean/`](../boolean/README.md); the former PathOps topology graph,
coincidence propagation, traversal, contour writer and `AsWinding` output pass
have been removed. Neither implementation links a C/C++ geometry library.

## Source and license

The translation is based on Google Skia commit
`1c2b83b5af8f53181742af1505edd18c2418c777`, primarily
[`src/pathops`](https://github.com/google/skia/tree/1c2b83b5af8f53181742af1505edd18c2418c777/src/pathops)
and selected
[`SkGeometry`](https://github.com/google/skia/blob/1c2b83b5af8f53181742af1505edd18c2418c777/src/core/SkGeometry.cpp)
helpers. The revision records provenance; it is not a build dependency.
Skia's BSD three-clause license remains in [LICENSE](LICENSE), and the
translated files retain their copyright notices.

| Retained implementation | Responsibility |
| --- | --- |
| `numeric.zig`, `point.zig`, `roots.zig`, `curve.zig` | Binary64 predicates, compensated arithmetic, polynomial roots and line/quadratic/cubic queries |
| `Intersections.zig`, `intersections/` | Primitive intersection dispatch, paired source parameters, `SkTSect` subdivision and bounded refinement |
| `reduce.zig` | Degree reduction used by the retained TSect regression tests |
| `winding.zig` | Read-only Bézier ray winding used by stroke-section regression probes |

These modules are implementation details. Path crossing queries preserve
source path, contour and parameter identities. They do not construct filled
regions. `windingAt` consumes an existing Path and returns a signed count; it
has no contour normalization or output responsibility.

## Numeric and resource contracts

Coordinates, controls, intersection parameters and result storage remain
`f64`. Coordinate ULP policies and parameter epsilon policies remain distinct.
The retained implementation preserves the reference's static and instance
point-comparison rules, compensated line solving, polynomial coefficient
scaling and explicitly fused evaluation order. It does not globally flatten
curves or introduce a root-polishing pass.

Primitive crossing queries disable optional near observations and diagnose
unresolved contacts. Shared-coordinate reduction and the conservative
separation certificate retain their existing domain and error bounds,
documented in [intersections/README.md](intersections/README.md). An
inconclusive certificate leaves TSect and its compensated refinement intact.

Curve-pair intersection uses operation-local scratch storage with the standard
4 KiB `BufferFirstAllocator` and arena fallback. The local buffer is an
allocation optimization, not a geometry limit. Allocation failures and
intersection work limits propagate as errors; unresolved events do not become
partial successful crossing results. Source curves are borrowed for a query,
and returned points and parameters are values.

## Continuing verification

The curve, root, numeric and primitive-intersection unit tests remain. All
public path-crossing and stroke-section regression tests remain unchanged,
including their allocation-failure checks and the raw-circle/canonical-region
comparison. Public region regressions also remain unchanged by this cleanup:

| Retired internal test subject | Continuing public checks |
| --- | --- |
| Curved direction, nested holes/islands and concave containment | `tests/region/reference.zig`: nested holes, concave bounds and curved direction |
| Repeated winding, reversed contours and self crossings | `tests/region/reference.zig`: four-fill matrices and repeated traversal; `tests/region/operations.zig`: fill-rule checks |
| Glyph O ink and counter | `tests/region/reference.zig`: exact glyph O boundary cut |
| Empty/retraced geometry and retained cubics | `tests/region/operations.zig` and the unchanged 84-operation fixture corpus |
| Allocation ownership | Public region and stroke-section allocation-failure tests |

Tests of deleted graph nodes, alias rings, span traversal, writer storage and
`AsWinding`'s internal walk splitting were removed with those implementations.
They are not counted as tests passing against the replacement Boolean engine.
The public checks above exercise the supported behavior; they do not assert
the retired implementation's internal representation or allocation pattern.

```sh
zig build test-region test-region-operations test-region-geometry -Doptimize=ReleaseSafe -j2
```

Region benchmarks measure the current production region implementation. Old
PathOps or C++ measurements are historical references, not measurements of
this retained crossing-query subset.
