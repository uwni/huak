# Intersection certificates and reductions

`separation.zig` supplies a sufficient exclusion test for a pair of cubic
Bézier curves. `sect.zig` uses it at the start of `binarySearch`, after clearing
the result and setting its capacity, before subdividing either curve.

The certificate proves that no parameter pair can satisfy the existing point
acceptance predicate, including its allowance for near contacts. It does not
replace root finding, change an acceptance tolerance, or interpret an empty ray
intersection as proof that the original curves do not intersect. A `false`
result means only that separation was not proved; TSect, ray intersection,
coincidence handling, and compensated refinement then run as before.

## Domain and arithmetic assumptions

The proof below applies to the current binary64 implementation under
round-to-nearest arithmetic, gradual underflow, and the explicit fused operation
used by `DoubleDouble.product`. It does not assume reassociation or fast math.

The certificate requires:

- Two cubic curves with finite stored control coordinates.
- Parameters in the complete interval `[0, 1]` for each curve.
- `S = max(1, absolute value of every input control coordinate) <= 2^100`.
- One coordinate with exactly equal corresponding controls on the two curves.
- Monotone controls in that shared coordinate, with a strictly positive middle
  control step after choosing the increasing or decreasing direction.
- Strictly one-sided corresponding control differences in the other
  coordinate, large enough for the bounds below to prove separation.

Either coordinate can be shared, and either monotone direction is supported.
Subnormal input coordinates and signed zero are allowed. If they make any
positive bound inconclusive, the certificate returns `false`. Nonfinite inputs,
larger magnitudes, different curve degrees, or nonmatching shared controls also
retain the existing path.

These conditions are deliberately sufficient rather than exhaustive. In
particular, constant shared coordinates and some monotone cubics with a zero
middle step are left to the existing intersection algorithm.

## Geometric proof

Write the curves as `A(t) = (A_X(t), Y(t))` and
`B(u) = (B_X(u), Y(u))`; exchanging axes gives the other case. The four controls
of `Y` are identical in both curves. Choose its direction so the successive
control differences are nonnegative, and let

```text
Δ = directed(Y₂ - Y₁) > 0.
```

Choose the sign of `X` so all corresponding control differences are positive.
Let `G` be a lower bound on their minimum, and let `M` be an upper bound on the
derivative magnitude of `B_X`:

```text
G <= min_i signed(A_Xᵢ - B_Xᵢ),
M >= 3 max_i |B_Xᵢ₊₁ - B_Xᵢ| >= max_[0,1] |B_X'(u)|.
```

The Bernstein basis is nonnegative and sums to one on `[0, 1]`. Thus the
same-parameter signed gap is at least `G`. The derivative bound then gives, for
arbitrary `t` and `u`,

```text
|A_X(t) - B_X(u)| >= G - M |t - u|.
```

Let `E` bound the exact coordinate difference of any contact the existing
floating-point predicate could accept; its derivation follows below. If a
contact were accepted, `|A_X(t) - B_X(u)| <= E` would force

```text
|t - u| >= h = (G - E) / M.
```

Only positive `h` is useful. If its lower bound exceeds one, no parameter pair
in the domain is possible. An exactly constant `B_X` also cannot close a gap
`G > E`; the implementation's outward upper bound on `M` remains positive even
in that case, so division does not require a separate constant-curve rule.

The derivative of the shared ordinate contains a nonnegative middle term:

```text
directed Y'(s)
  = 3 Δ₀ (1-s)² + 6 Δ s(1-s) + 3 Δ₂ s²
 >= 6 Δ s(1-s).
```

Among subintervals of `[0, 1]` with length `h`, the integral of `6s(1-s)` is
smallest at an endpoint. For `0 <= h <= 1` that minimum is
`3h² - 2h³ >= h²`. Therefore an accepted contact would also have to satisfy

```text
|Y(t) - Y(u)| >= Δ h².
```

If a lower bound on `Δ h²` exceeds `E`, this contradicts the necessary
shared-coordinate proximity. Both exact intersections and contacts permitted
by the existing approximate predicate have then been excluded.

## Existing point acceptance

Let `ε = 2^-52`, the value of `numeric.EPSILON`, and `u = ε/2`. The comparison
is derived from `Point.approximatelyEqual`; it does not replace that function.
Its necessary coordinate conditions are intentionally easier to bound than
its final distance check:

1. The initial absolute-coordinate shortcut requires each rounded difference
   to be smaller than `ε`.
2. Otherwise, each coordinate must pass `roughlyEqualUlps`, whose ordinary
   budget is strictly fewer than 256 ULPs.
3. That same helper also accepts two coordinates whose absolute values are
   both at most `512 ε`. Their difference is at most `1024 ε`.

For evaluations with magnitude below `2S`, 256 ULPs span less than
`512 ε S`; this also covers the spacing below the normal range. The
absolute-coordinate alternatives are bounded by `1024 ε S` because `S >= 1`.
Thus `1024 ε S` is a conservative necessary bound between *evaluated*
coordinates. Ignoring the final, stricter distance check only makes exclusion
more conservative. Exact equality and `approximatelyDEqual` have no wider
necessary coordinate condition.

We must additionally account for the difference between an evaluated
coordinate and the exact cubic at its stored parameter. This matters when the
certificate runs before TSect subdivision, rather than only before DD
refinement.

## Compensated evaluation error

Let `η = 2^-1074`, one minimum positive subnormal. The following bounds use `η`
as an absolute allowance for a possible underflow rounding; they do not assume
every product residual is representable.

For finite intermediates, `DoubleDouble.sum` is the error-free TwoSum
transformation. A normalized pair `a = (a.hi, a.lo)` satisfies the conservative
bound

```text
|a.lo| <= 2u |a.hi| + 2η.
```

`DoubleDouble.product` computes the rounded product and its FMA residual.
Their represented sum differs from the exact product by at most `η`: away
from residual underflow the residual is exact. All prepared position controls
start with a zero low part. The final TwoSum in each DD addition restores the
normalized-pair property.

For DD addition, the high, low, middle, and result TwoSum transformations are
exact. The only omitted information comes from rounding the final expression

```text
(result.lo + middle.lo) + low.lo.
```

Set `H = |a.hi| + |b.hi|` and `L = |a.lo| + |b.lo|`. The normalized-pair bound
gives `L <= 2u H + 4η`. Applying the scalar rounding bound
`|RN(x)-x| <= u|x| + η` to the TwoSum high parts bounds the sum of the three
tail magnitudes by `3u H + 8η`. The two tail additions consequently lose at most

```text
u(2+u) (3u H + 8η) + (2+u)η
  <= 16u² H + 32η.
```

This bound allows cancellation of the high parts; it is absolute rather than
a relative bound on the final answer. With `N(a) = |a.hi| + |a.lo|`, applying
it to the four product terms and three additions in the unchanged DD
multiplication order gives the conservative bound

```text
|represented(a.mul(b)) - exact represented(a) * represented(b)|
  <= 128u² N(a)N(b) + 256η.
```

For example, the partial-product norms sum to at most
`(1+2u)N(a)N(b) + 16η`; each of the three accumulated-addition high-part sums
is below `2N(a)N(b) + 64η`. The three addition errors and four product residual
allowances fit inside the stated bound. The scalar multiplication shortcut
retains the same DD result in its documented domain and uses the original
multiplication otherwise, so it does not change this accounting.

The DD weights represent `t` and `1-t` exactly; the latter uses TwoSum through
the subtraction of two zero-tail DD values. Their exact sum is one. Each
de Casteljau stage is a convex combination. If the preceding stage's absolute
error is at most `e`, the product and addition bounds above give the relaxed
stage bound

```text
e_next <= e + 512u²(S + e) + 1024η.
```

There are only three stages for a cubic. Starting from exact controls gives
an error below `2048u² S + 4096η` before converting the final DD pair to one
binary64 value. That conversion adds at most `u` times its magnitude plus `η`.
The resulting position error is below `2 ε S` per coordinate.

The magnitude limit on `S` makes all these position-evaluation intermediates
finite. The small `η` allowances are negligible compared with `ε² S` because
`S >= 1`; they are included to cover the smallest parameter and coordinate
products. This argument concerns position evaluation, not an unrestricted
error bound on the Newton quotient or on arbitrary DD programs.

## Ordinary evaluation and the margin ledger

`Cubic.ptAtT` evaluates the four Bernstein terms and their sum. TSect obtains
subcurve endpoints from the original curve's `subDivide`, using `chopAt` or
three interpolation stages in `interpPoint`. It does not repeatedly subdivide
the already rounded subcurve to obtain those endpoints.

For `t` in `[0, 1]`, `interp(a,b,t) = a + (b-a)t` has absolute rounding error
below `8u` times a bound on the input magnitudes, including cancellation in
`b-a`. Three such stages, or the direct Bernstein evaluation and its weight
roundings, fit well inside `64 ε S` per endpoint coordinate. The special
midpoint subdivision expressions have the same bound. This permits evaluated
magnitudes below `2S`, as used in the point-predicate bound above. All of these
small fixed operation sequences stay far below overflow for `S <= 2^100`.

The exclusion margin is

```text
E = 4096 ε S.
```

Its conservative ledger is:

| Contribution | Bound per coordinate |
| --- | ---: |
| Necessary comparison between evaluated coordinates | `1024 ε S` |
| Two ordinary endpoint/source-evaluation errors | `128 ε S` |
| Total needed for ordinary or DD event comparisons | less than `1152 ε S` |
| Margin used by the certificate | `4096 ε S` |

The DD error is smaller than the ordinary allowance, so it does not need a
second additive budget in the same comparison. The margin is a bound for
rejecting work; the existing comparison thresholds, root solver, and 64-step
refinement budget remain unchanged. Its value is not inferred from a passing
fixture or borrowed from an unrelated epsilon policy.

## Directed bounds and call placement

The input controls are the exact stored binary64 numbers. Multiplication by
the chosen signs is exact. The implementation steps each computed bound one
representable number outward with `nextAfter`:

- `G` and the positive middle step are rounded downward.
- Absolute control differences and `M` are rounded upward.
- Subtraction of `E`, division by `M`, and both products in `Δ h²` are rounded
  downward.

An upper derivative bound is strictly positive even when its exact value is
zero. A nonpositive lower bound on `h` cannot certify anything. Division
overflow can yield a lower bound greater than one, which safely proves that
the required parameter separation is impossible. Underflow only weakens the
positive lower bounds or causes fallback. In the admitted domain,
`4096 ε S = 2^-40 S` is an exact power-of-two scaling, with no overflow or
underflow of the margin itself.

The predicate concerns the complete original parameter intervals. It can
therefore run once at the pair's `binarySearch` entrance rather than once for
every failed ray candidate. Existing endpoint, closest-endpoint, removed-end,
perpendicular/coincidence, ordinary tangent, and compensated event paths all
use exact equality or the bounded point comparisons above. Initial spans and
subsequent bounded spans describe parameters within `[0, 1]` of the original
curves. The certificate does not justify pruning unrelated extrapolation,
other approximate predicates with wider allowances, or another evaluator with
an unreviewed forward-error bound.

Regression tests should exercise both successful exclusions and conservative
fallbacks: exchanged axes, decreasing shared controls, endpoint derivative
zeros, small and large scales, near contacts, tangent contacts, actual roots,
nonmonotone controls, and nonfinite or out-of-domain magnitudes. Those tests
check the implementation against its contract; they are not a substitute for
the separation and error bounds above.

## Shared monotone-coordinate reduction

The curve-pair dispatcher tries this reduction before it calls TSect. Tests of
subdivision call TSect directly so the reduction cannot hide a numerical error.

`shared_coordinate.zig` handles equal-degree quadratic or cubic curves whose
corresponding controls share an exactly equal coordinate. Strictly monotone
controls make that coordinate injective: equality of curve positions requires
`t = u`. Matching controls in reverse order instead requires `u = 1 - t`.
If all aligned controls also agree in the other coordinate, the curves
coincide over their full length. Both exact and near queries return the two
endpoints of that interval, pairing parameters in the matching direction.
Injectivity rules out additional parameter pairs, including self-crossings.

For a nonzero difference, near queries use the general intersection path to
retain near-endpoint observations. Exact queries solve the scalar Bézier
polynomial with `Quad.horizontalIntersect` or `Cubic.horizontalIntersect`.
Every control difference must be finite, with a zero TwoDiff low component,
and must round-trip through power-of-two normalization. Nonmatching controls,
a nonmonotone shared coordinate, or failed arithmetic checks defer to the
general intersection path. Every solved root also passes the original
source-point residual predicate before results are committed.
Parameters stay in the original source domains; stored points are evaluated
on the first original curve. This reduction uses no caller tolerance or new
root solver, and does not label isolated roots as coincident intervals.

## Perpendicular probes in TSect

To test coincidence, TSect intersects the other curve with the normal through
a sampled point. The scalar projection is a cross product: its absolute value
equals the distance to that line times the length of its direction vector.
A short tangent used to shrink the residual enough for an inaccurate root to
pass the scalar check and then fail the point comparison. At `t = 1/4` in the
regression curve, that disagreement split a continuous overlap into pieces.

TSect divides the normal by `min(1, max(abs(dx), abs(dy)))` and passes the
origin and direction separately. The resulting normal has length at least
one and a length at least as large as the input normal. The existing scalar
threshold therefore bounds geometric distance without relaxing its previous
limit. A zero tangent has no normal direction.
