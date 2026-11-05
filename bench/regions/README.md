# Region performance measurements

`bench/regions.zig` measures the production `core.region.combine` call,
including coordinate mapping and result destruction. Each original fixture is
validated against independent source-curve coverage before timing. Fixture
creation, verification and rendering are outside the timed intervals.

```sh
zig build bench-regions -Doptimize=ReleaseFast
zig build bench-regions -Doptimize=ReleaseFast -- --case near_coincident_1e-4 --repeats 10000 --trials 7
zig build bench-regions -Doptimize=ReleaseFast -- --allocations
```

Without arguments, all 21 fixtures retain their original operation, tolerance,
repetitions and three trials. Case selection and longer trials support CPU
sampling without changing production algorithms. `--allocations` runs an extra
untimed operation through the standard library's tracking allocator. Reported
allocated/freed bytes are cumulative requests, not peak live memory.

## Balanced comparison

The separate runner executes already-built benchmarks serially. It does not
link, fetch or rebuild any reference implementation:

```sh
zig build bench-regions-compare -Doptimize=ReleaseFast -- \
  --cpp target/pathops-perf/cpp-reference \
  --before target/pathops-perf/zig-before \
  --after target/pathops-perf/zig-after \
  --rounds 12 --output target/pathops-perf/comparison
```

Each executable first performs one excluded warmup. Measured rounds cycle
through all six execution orders. Use a multiple of six for complete balance;
the report marks incomplete cycles explicitly. Do not run other builds, tests
or benchmarks during measurement. The output directory retains exclusive raw
stdout/stderr logs, per-round CSV/JSON and `summary.json`; existing results are
not overwritten.

The runner requires successful child exits, all 21 cases, matching configuration,
operations, physical tolerances and repetitions. Trial medians and checksums
are checked, and each implementation must preserve its own warmup output
counts. Different implementations may emit different redundant boundary
commands. Input/source provenance must be established separately; matching
labels alone does not prove identical geometry.

For each case and implementation, the summary reports the median/min/max of
the per-process hot medians. Each process uses its original three trials. An
even number of rounds averages the two middle observations. Process elapsed
time includes fixtures and verification; it is not the kernel time. RSS is a
cumulative whole-process high-water mark. Per-case first calls are within one
process, not independent cold starts. These measurements provide no statistical
confidence interval or universal speed guarantee.

The October 2026 C++ reference is a retained, already-verified local migration
artifact; its binary and static archive hashes and input cache manifests are
recorded with that run. Repeating that comparison requires those artifacts or
an independently supplied equivalent reference. C++ sources, bridge code and
Skia package/build dependencies remain absent from production. See
[verification](../../docs/verification.md) for the actual measurements and scope.
