# Curve Boolean kernel

Pure Zig, binary64 port of Paper.js **v0.16.0**, under the adjacent MIT
license. No JavaScript runtime is involved in production. The source tag is
<https://github.com/paperjs/paper.js/tree/v0.16.0>.

| Upstream file | Git blob | Zig responsibility |
| --- | --- | --- |
| `src/util/Numerical.js` | `923768818e44165fb021ce4f060946f39f4dab78` | `numeric.zig` |
| `src/path/Curve.js` | `60ff9755eadefbb494c720b9082119acedba374c` | `curve.zig`, `intersections.zig` |
| `src/path/CurveLocation.js` | `85350d0b0f6438c0de45a0fddad8eacf84923aef` | paired locations in `intersections.zig` and `graph.zig` |
| `src/util/CollisionDetection.js` | `ecd8a9342415bc155bf06aef515718673721ae41` | `collisions.zig` |
| `src/path/PathItem.Boolean.js` | `c5516f2c8e13be30c396a78e5b06b88a2a0c7ffe` | `graph.zig`, `regions.zig` |

`path.zig` prepares closed contours using Paper's relative handles and
`Path.reduce` rules; the same reduction is applied to traced results.
`operation.zig` owns the arrangement arena and a separate construction workspace.
The workspace and intersection events are released before tracing. Tracing owns
its own temporary arena; all three arenas end before output reduction. Input
nodes use one precisely sized buffer, reused across both operands and freed
before construction. Only an independently owned Huak Path leaves the operation.
`types.zig` contains only shared curve and intersection records.
Curve-local geometry is the shared `geometry.Cubic` struct with named
`p0`..`p3` points, and bounds are the shared `geometry.BBox`; the kernel does
not define duplicate `Cubic`/`Bounds` records or numeric field adapters.
Explicit formulas use the named points directly, while homogeneous scans
(four controls, six control pairs, vertex fans) use small local arrays or
flat runtime arrays. Vertex fans are one flat `outgoing` slice with
per-vertex ranges instead of one allocation per vertex. SoA columns are
reserved for a batch kernel only after a contiguous scan is measured to win;
the fat-line, root-isolation and union-find kernels remain AoS because their
control flow, not field layout, is the cost.

Completed edges own their forward controls; half-edges borrow those controls or
one batch of reversed controls. Their angular sorting workspace is reused per
vertex. Sorting each vertex fan directly links the incoming twins; faces traverse
these links without a duplicate edge list. Construction samples, cuts, candidate
lists and sorting buffers never become references in the completed arrangement.
Source, initial sample/cut, vertex and half-edge capacities are reserved before
population; edge capacity is bounded by the completed cuts. Adjacent source
curves share an exact endpoint sample through their closed-contour links. The
sample-to-vertex mapping is refreshed after each merge pass, so subsequent
construction lookups do not repeat union-find searches. The
pending split stack stores parameter intervals, not copied Bézier controls.
Result reduction reserves scratch from each closed contour's known node count
and edits the owned output buffer, without a second complete output path.

Intersection events allocate their contour-length cache on first use, then each
contour is measured once. Pair overlap
checks retain their four endpoint membership results for the following endpoint
stage, with the query tolerance as part of that reuse contract. Intersection events
and collision rows transfer their existing buffers. Events cache the first point
used by duplicate detection; graph construction evaluates a second point only
when creating its cut and sorts indices into the events. Exact duplicate
curve parameters share one cut while retaining every event pairing; no proximity
tolerance is added. These storage changes preserve the numerical expressions,
event order and graph algorithm. Curve-local counts and sample sorting reuse
one index buffer. Face propagation and boundary tracing reuse one work list;
component bounds have one storage location and ray buffers use the known
component count.

Before a curve pair enters the fat-line recursion, a conservative control-hull
relation rejects hulls separated by more than the accepted tolerance. When the
two curves share exactly one endpoint, a line through that endpoint with the
two control sets on opposite sides proves that no other point is shared: each
curve lies in its closed half-plane by the convex-hull property, its Bernstein
basis is strictly one-signed in the interior, and the other endpoints are not
shared. The exact shared endpoint is therefore the complete intersection and
is emitted directly; no fixture name, curve type, join smoothness or input
size participates in the decision. Event-level rounding may change the last
bits of a shared-endpoint tangency, but the intersection set and covered
region are unchanged.

The structural-zero guard compares the two coordinate/normal pairs together,
so the normal's zero mask can be reused across controls. The dot product and
its error bound keep their scalar expressions. Candidate curves use ordinary
iteration rather than forcing two copies of the complete hull classifier.

Graph construction sorts each source's eligible vertices along its wider
coordinate axis. Each snapped piece queries the inclusive interval of its own
control box. Projecting the four controls onto the chord normal gives a strip
containing the entire Bézier. Vertices outside that strip by more than the
tolerance and rounding margin can be discarded before nearest-point queries.
The surviving vertices are probed in their original ID order, preserving the
choice of the first accepted split when several vertices qualify.

Short-span merges compare the vertex chord
with the length threshold before integrating, zero-length length queries
return zero, a start location reuses the contour offset, cut and vertex-fan
capacities are reserved from known counts, a line-distance evaluation shares
one baseline denominator, and the implicit-root list is reused per operation.

The following adaptations are intentional and apply to every input:

- Translate both operands around their common bounds midpoint, and use a power
  of two derived from the requested spatial tolerance as the coordinate unit.
  Restore binary64 coordinates with the existing representability check.
- Retain the upstream diagonal-based geometric resolution and floating-point
  magnitude floor. Cap the geometric term at one eighth of the requested
  spatial tolerance: the graph removes spans shorter than four times its
  epsilon, so each boundary receives at most half that spatial budget. This
  prevents a distant component from erasing tolerance-sized local gaps.
- Preserve the association between both locations of each intersection when
  constructing graph vertices. Independently rounded evaluations need not be
  rediscovered as the same event by coordinate distance.
- Test curve coincidence with the existing tolerance-aware `Curve.getTimeOf`.
  Nearest-point projection uses a different parameter stopping tolerance and
  cannot establish this membership predicate.
- Sort numerical roots numerically. JavaScript's default lexicographic array
  sort can reverse roots written in ordinary and scientific notation.
- Apply nonzero, evenodd, positive and negative rules directly to the signed
  face windings. Raw overlapping contours are not independently reoriented.
- Report exhausted curve-intersection recursion as `GeometryWorkLimit`, rather
  than silently returning incomplete intersections. Public input/output and
  allocator-failure contracts remain those of `region.Options`.

There is no polygon flattening, root-polishing fallback, per-fixture tolerance
or alternate backend. The original region fixtures and stroke-section tests
exercise the public API. Isolated upstream differential tests and measurements
are recorded in `docs/verification.md`.
