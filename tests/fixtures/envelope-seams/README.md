# Closed-stroke seam experiment

The production engine prefers existing smooth knots. This directory retains
the comparison inputs and native precision probe. The former Node comparison
and report generators have been removed; previously generated data remains in
`target/seam-comparison`. Current automated coverage runs through
`zig build test-pen-envelope`.

In the retained comparison, `inputs.json` supplied both generated scripts.
The first MetaPost column is
real `draw p` on a closed path. The second is real
`draw subpath(0.5,length p+0.5) of p`, explicitly using round caps: this is an
open path with coincident endpoints, not MetaPost's default closed-path rule.
The third is the actual installed Huak CLI's `stroke_outline` filled once.
Every input uses an explicit polygon nib; these observations do not apply to
MetaPost's separate elliptical-pen rendering branch.

All 27 SVGs are rasterized with the same librsvg settings at 8 pixels per pt;
binary alpha coverage uses a 50% threshold. No SVG path parser or envelope
implementation participates in calculating differences. Results retain tool
versions, the shared-input hash, the actual Huak executable hash, raw images,
and individual pixel counts. Pixel counts are not exact areas or a continuous
geometry-equivalence proof.

Generated plates:

- `comparison.svg/.png`: square miter and enlarged source corner.
- `controls.svg/.png`: acute miter, bevel, round, and miter-limit controls.
- `reindexed.svg/.png`: unchanged geometry with a different source start knot.
- `comparison.mp`, `comparison.huak`, `results.json`: reproducible evidence.

## Precision counterexample

This separate probe uses four cubic segments whose existing nodes are already
smooth. All input controls and square offsets are even integers, exactly
representable both normally and after adding `(1e16,1e16)`. The Zig probe
asserts this before invoking the production `strokeOutline`, then normalizes
actual output primitives before sampling or line parameterization.

```sh
mkdir -p target/seam-comparison/precision
zig run -OReleaseSafe --dep drawing \
  -Mroot=tests/fixtures/envelope-seams/precision.zig \
  -OReleaseSafe -Mdrawing=src/drawing/root.zig \
  >target/seam-comparison/precision-native.log \
  2>target/seam-comparison/precision-native.csv
cd target/seam-comparison/precision
/Library/TeX/texbin/mpost --numbersystem=double --interaction=nonstopmode \
  --halt-on-error ../../../tests/fixtures/envelope-seams/precision.mp
cd ../../..
```

The retained precision plate plots returned control data; it computes no envelopes or
subdivision. In the initial 2026-10-27 run, always splitting the first segment
introduced a 1 pt maximum control-coordinate difference and a 0.452061886 pt
maximum displacement among 1025 corresponding samples per cubic. The sample
metric is not a visible-boundary Hausdorff distance. The probe reports actual
measurements rather than asserting that an error must keep occurring after a
future correction.

The evidence supports avoiding a corner as the construction cut when its
miter/bevel choice should be retained. It does **not** support always adding
a subdivision, nor does it establish pixel compatibility with original
MetaPost output. The corrected production engine now prefers an existing
smooth knot; the formal regression in `tests/pens/envelope.zig` checks exact
normalized primitives and coverage for the large-origin case. The precision
probe reports zero control-coordinate and sampled displacement after that
correction; original before-fix artifacts are retained separately.
