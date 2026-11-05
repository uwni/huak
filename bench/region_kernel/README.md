# Historical exact curve-region experiment

This is a historical candidate experiment. Production now uses the
[pure Zig Skia PathOps port](../../src/drawing/region/pathops/README.md);
CGAL is not part of the production build. The isolated C++ research sources,
build scripts and dependency manifest have been removed. This document retains
the experiment's scope, provenance and measurements; it is not a runnable
benchmark or a pending backend selection.

The experiment tested CGAL's public Bézier arrangement API. Original cubic
control points remained curves; no polyline conversion was used.

The input adapter exactly promoted IEEE-f64 coordinates to rationals. It
canonicalized a complete control-point sequence against its reversal and
retained the original orientation as signed winding data. CGAL performed curve
splitting, intersections, overlap detection and arrangement topology. Face
winding selected nonzero, evenodd, positive or negative regions; selected
boundary curves were exported through bounded f64 rounding.

The experiment pinned [CGAL 6.2.1](https://github.com/CGAL/cgal/tree/28811b671a12b5caa9e3688569dadbc6b3728fe6)
and Boost 1.91.0, with installed GMP and MPFR. No upstream source or dependency
package is tracked here. Runtime logs and process summaries remain under
`target/region-kernel/`; the tracked source history preserves the original
experiment and its dependency pins.

The 65 winding checks below belonged to this research program. They were not a
production acceptance suite, and this archive does not claim that the current
Zig regressions reproduce all 65 checks. Current production inputs and
contracts are maintained in [tests/region](../../tests/region/README.md) and
[tests/fixtures/regions](../../tests/fixtures/regions); the current benchmark is
[bench/regions.zig](../regions.zig).

Each numeric case reported separate source construction, arrangement insertion,
classification and curve-export stages. Decimal and tiny cases used explicit
process timeouts: the earlier polygon-set route exceeded 20 seconds on these
inputs. Passing integer cases did not establish practical performance for
arbitrary f64 curves.

The polygon-set route and incremental-insertion experiment are intentionally excluded. Historical findings are not proof that every degeneracy or scale is supported. This route was not adopted into the production engine.

## First real run

ReleaseSafe, locked CGAL 6.2.1, canonical support and batch arrangement insertion:

| Case | Result | Process wall time |
| --- | --- | ---: |
| Integer-valued cubic lens | Valid one-loop boundary, four cubic segments, bounded export | 163 ms |
| 65 winding and Boolean cases | All passed, including independent reversed cubic supports, four fill rules, tangent contact, shared edge, cubic self-intersection, and holes | 559 ms |
| Decimal-f64 cubic lens | Killed at the explicit 20-second process timeout | >20,000 ms |

The decimal case constructs each coordinate as `0.1 + 0.01 * coordinate` in f64, then promotes that exact f64 to a rational. Its source curves were ready after 0.182 ms. Arrangement construction did not return before the timeout; classification and curve export were never reached. Therefore an export-only optimization does not address this observed cost. This route is not yet demonstrated practical for ordinary f64 drawing inputs.

The integer conversion check verified that `Rational(0.1) * 2^55 == 3602879701896397`; inputs were not silently converted to decimal approximations.

The native APIs are documented by CGAL's [Bézier arrangement traits](https://doc.cgal.org/latest/Arrangement_on_surface_2/classCGAL_1_1Arr__Bezier__curve__traits__2.html) and [curve data traits](https://doc.cgal.org/latest/Arrangement_on_surface_2/classCGAL_1_1Arr__curve__data__traits__2.html).

## Validation and production-check isolation

The first timing bundled an explicit `arrangement.is_valid()` call into construction. The later proof reported x-monotone preparation, the public `CGAL::insert` call and optional explicit validation separately. Explicit validation ran only when `CGAL_PROOF_VALIDATE` was set. Face-winding consistency, known interior/exterior point expectations, boundary traversal and bounded export used ordinary exceptions and remained enabled in every build.

Two ReleaseSafe builds of the same source were tested. The first explicitly
defined `CGAL_DEBUG`; the second explicitly defined `NDEBUG`. Each process
printed the actual resulting macro values. CGAL documents these controls in
its [checks manual](https://doc.cgal.org/latest/Manual/devman_checks.html).

| Decimal-f64 lens configuration | Actual macros `NDEBUG / CGAL_NDEBUG / CGAL_DEBUG` | Last completed stage | Result |
| --- | --- | --- | --- |
| Checks enabled, explicit validation skipped | `0 / 0 / 1` | Before insertion: 0.404 ms | Insertion did not return within 20 s |
| Production checks disabled, explicit validation skipped | `1 / 1 / 0` | Before insertion: 0.408 ms | Insertion did not return within 20 s |

These runs establish that the observed decimal case spends its time inside public arrangement insertion before the separate validator or exporter is reached. They do not establish the cost of every f64 input.

The production configuration passed the integer lens in 148 ms, or 189 ms with explicit member validation enabled, and all 65 winding/export cases in 537 ms. These are single diagnostic process runs, not a statistical performance benchmark. Logs and structured process records are in `target/region-kernel/`.
