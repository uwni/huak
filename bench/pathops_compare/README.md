# Historical path Boolean comparison

This directory archives the original comparison results for Clipper2, upstream
CPU Skia PathOps with float storage, and lib2geom PathIntersectionGraph. The
experimental programs, native adapters, dependency manifest and extracted
research dependencies have been removed after the production binary64 Skia
PathOps migration. The JSON files remain unchanged as historical evidence.
The current production algorithm is a [pure Zig translation](../../src/drawing/region/pathops/README.md),
with no C++ geometry library or private geometry C bridge.

Current deterministic inputs and the independent coverage/control-point checks
live in [tests/fixtures/regions](../../tests/fixtures/regions). The production
regressions are in [tests/region/regressions.zig](../../tests/region/regressions.zig),
and [bench/regions.zig](../regions.zig) measures the production implementation:

```sh
zig build test-region -Doptimize=ReleaseSafe -j2
zig build bench-regions -Doptimize=ReleaseFast -j2
```

The archived results record observed statuses, original fill rules,
normalization, sampled errors and medians. These were Boolean-adapter
experiments: Clipper returned a native Huak Path, whereas the other candidates
returned C element buffers without final Huak Path reconstruction. Rendering,
full picture composition and primitive canonicalization were excluded. The
last result was released after the timer, while preceding replacement releases
were timed. Coverage sampling and the float input guard did not establish exact
topology or a general tolerance bound.

lib2geom accepted only evenodd operands in that experiment. The equivalent
evenodd corpus was explicitly retagged; unsupported nonzero operands were not
treated as equivalent. Normalized modes used one common origin and scale for
both operands. lib2geom's precision argument was `tolerance / 4` in normalized
units, rather than a guaranteed Hausdorff bound. These historical results do
not measure the current f64 port or establish its current performance.
