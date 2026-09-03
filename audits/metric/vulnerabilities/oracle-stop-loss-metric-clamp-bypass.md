# Clamping per-share metrics to uint104.max silently disables the oracle stop-loss

## Severity

Medium

Once a bin's true value-per-share metric exceeds `type(uint104).max`, the stop-loss records only the clamp ceiling. Any later metric that remains above the ceiling is also clamped to the same value, so an arbitrarily large percentage drawdown can be invisible to the extension.

The end-to-end PoC demonstrates a permissionless swap that extracts approximately `9%` of LP value at a constant, correct oracle price while the configured maximum drawdown is `5%`. The swap succeeds because the pre-attack and post-attack metrics both clamp to `uint104.max`.

The issue is best classified as Medium rather than High because it requires a pool whose per-share metric has entered the saturated range and liquidity at a sufficiently displaced execution price. The PoC parameters are accepted by the pool's parameter bounds, but the affected state is still configuration- and market-dependent.

## Summary

`OracleValueStopLossExtension` computes token0- and token1-denominated value-per-share metrics as `uint256`, but immediately clamps each result to `type(uint104).max`:

```solidity
metricT0 = _clampMetric(
  t0ps + Math.mulDiv(Math.mulDiv(uint256(t1), Q64, midPriceX64), METRIC_SCALE, shares)
);

metricT1 = _clampMetric(
  Math.mulDiv(Math.mulDiv(uint256(t0), midPriceX64, Q64), METRIC_SCALE, shares) + t1ps
);
```

```solidity
function _clampMetric(uint256 metric) private pure returns (uint256) {
  return metric > METRIC_MAX ? METRIC_MAX : metric;
}
```

The clamped values are then used both as the current metrics and as the stored high watermarks.

If the real high watermark is `H > METRIC_MAX`, the extension stores only `METRIC_MAX`. If LP value subsequently falls to any `V >= METRIC_MAX`, the current metric is also `METRIC_MAX`. `_applyWatermark()` sees `metric >= hwm` and reports no breach, regardless of the percentage loss between `H` and `V`.

Consequently, the stop-loss is silently disabled throughout the entire saturated interval.

## Affected code

- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol`
  - `METRIC_MAX`
  - `_metrics()`
  - `_clampMetric()`
  - `_checkAndUpdateWatermarks()`
  - `_applyWatermark()`
- `metric-core/contracts/MetricOmmPoolFactory.sol`
  - pool parameter validation permits per-share densities that can produce saturated extension metrics

## Root cause

The extension stores both high watermarks as `uint104` so that the two watermarks and the `uint32` timestamp fit into one storage slot:

```solidity
struct BinHighWatermarks {
  uint104 token0;
  uint104 token1;
  uint32 lastDecayTs;
}
```

Instead of preserving the full metric or its scale, the implementation discards all information above the storage maximum.

For token1-denominated value, the unclamped metric is approximately:

```text
metricT1 = ((token0 * oraclePrice) + token1) * 1e6 / shares
```

For token0-denominated value, it is approximately:

```text
metricT0 = (token0 + token1 / oraclePrice) * 1e6 / shares
```

The balances being `uint104` does not guarantee that either metric fits in `uint104`. The calculation also:

- multiplies value by `METRIC_SCALE = 1e6`;
- converts one token balance through a Q64.64 oracle price;
- divides by a potentially small `totalShares` value;
- permits factory-valid initial per-share densities much larger than the final metric storage range at some supported prices.

The contract comment that normal bins with `uint104` balances remain below the cap is therefore not a valid bound.

## Saturation removes the percentage guarantee

Let:

```text
C = type(uint104).max
H = true historical high metric
V = true current metric
D = configured drawdown fraction
```

When `H > C`, the extension stores:

```text
storedHwm = C
```

When `V > C`, it computes:

```text
storedCurrent = C
```

The breach check becomes:

```text
C < C * (1 - D)
```

which is always false.

The true check should have been:

```text
V < H * (1 - D)
```

As a result, value can fall from `H` to approximately `C * (1 - D)` before the extension can report a breach. The maximum invisible fractional drawdown is approximately:

```text
1 - C * (1 - D) / H
```

As `H/C` grows, the hidden drawdown approaches `100%`.

This is not only a precision loss near the integer boundary. Every value in the entire interval `[C, H]` becomes indistinguishable.

## Permissionless direct-loss path

The strongest PoC keeps the oracle price constant and correct:

1. A pool uses `OracleValueStopLossExtension` with `drawdownE6 = 50_000`, or `5%`.
2. Valid pool density, share supply, and oracle price values make the target bin's true token1 metric greater than `uint104.max`.
3. A separate permissionless dust swap initializes a genuine watermark. The true metric is approximately `1e33`, but the extension records only `uint104.max`, approximately `2.028e31`.
4. The oracle remains unchanged.
5. The pool cursor is at a valid `-10%` distance, so token0 can be purchased from the bin for approximately `90%` of its oracle value.
6. The attacker requests `0.9` token0 from a bin holding approximately `1` token0.
7. The attacker pays approximately `810,040,500` token1 for token0 worth `900,000,000` token1 at the unchanged oracle mark.
8. The bin's true value falls by approximately `9%`, exceeding the configured `5%` drawdown.
9. The true post-swap metric remains above `uint104.max`, so it is clamped to the same value as the watermark.
10. `_applyWatermark()` reports no breach and the swap succeeds.

The exploit transaction is a normal public swap. It does not require control of the pool admin, extension, factory, or oracle.

## Concrete PoC parameters

```text
drawdownE6:                         50,000 = 5%
decayPerSecondE8:                   0
minimalMintableLiquidity:           1 share
initialScaledAmount0PerShareE18:    1e36
actual token0 deposited:            1 token0
oracle price:                       1e9 token1 per token0
cursor distance:                    -100,000 E6 = -10%
attacker output:                    0.9 token0
```

These values satisfy the relevant factory-level numerical constraints:

- both initial per-share amounts are nonzero;
- `minimalMintableLiquidity` is nonzero;
- `initialScaledAmount0PerShareE18 = 1e36` is below `type(uint128).max`;
- the cursor distance is strictly inside `(-1e6, 1e6)`;
- the Q64.64 oracle quote fits in `uint128`;
- the pool's actual token balance fits in `uint104`.

No factory validation checks whether the resulting extension metric can exceed `uint104.max`.

## Observed result

```text
true metric before attack:
999999900000000050000000050000000

true 5% stop-loss floor:
949999905000000047500000047500000

true metric after attack:
910040400090000050043912435000000

stored clamped watermark:
20282409603651670423947251286015

token0 received by attacker:
0.9 token0

token1 paid by attacker:
810,040,500.090000000043912385 token1

value of output at unchanged oracle:
900,000,000 token1

attacker profit at unchanged oracle:
89,959,499.909999999956087615 token1
```

The unclamped metric falls below the true 5% floor, but the production extension compares:

```text
current metric = uint104.max
watermark      = uint104.max
```

and allows the approximately 9% loss.

## Additional repricing consequence

The same PoC file contains a second test in which the correct oracle price moves from `1e9` to `1e8`.

The true metric falls from approximately `1e33` to approximately `9.1e31`, a drawdown of more than `90%`. Both values remain above `uint104.max`, so the extension still sees no drawdown and permits the swap direction that the stop-loss is intended to block after the repricing.

The constant-price attack is the stronger impact demonstration because it proves direct value extraction without relying on stale data, an incorrect oracle observation, or a market-price transition.

## Proof of concept

The integration PoC is located at:

```text
metric-periphery/test/extensions/OracleValueStopLossClamp.audit.t.sol
```

It uses:

- the real `MetricOmmPool` swap and callback path;
- the real `OracleValueStopLossExtension` after-swap hook;
- real bin balances and shares;
- a separately initialized high watermark;
- numerical deployment values within the factory's bounds;
- a constant oracle price for the direct-loss test.

Run:

```bash
cd metric-periphery
forge test --match-path test/extensions/OracleValueStopLossClamp.audit.t.sol -vvv
```

Observed tests:

```text
[PASS] test_clampAllowsDirectValueExtractionAtConstantOraclePrice()
[PASS] test_clampHidesNinetyPercentTrueMetricDrawdown()
```

## Impact

For any saturated bin, `OracleValueStopLossExtension` no longer enforces its configured percentage-drawdown guarantee over the saturated range.

This can lead to:

- direct LP value extraction from swaps that should exceed the configured stop-loss;
- failure to block inventory outflow after a large, correct oracle repricing;
- watermarks that remain pinned at `uint104.max` despite major changes in LP value;
- identical behavior for the opposite direction when `metricT0` is the saturated metric.

The issue affects the extension's core purpose rather than only introducing small rounding error. The direct-loss PoC exceeds the contest's `1%` High percentage threshold, and sufficiently valuable deployed liquidity can exceed the absolute-value threshold. However, the special saturated-metric and cursor conditions are substantial enough that Medium is the more defensible classification.

## Preconditions and validity considerations

- The pool must use the first-party `OracleValueStopLossExtension` with an active drawdown.
- A bin's true per-share metric must exceed `type(uint104).max`.
- The target bin must hold relevant outgoing-token inventory.
- For direct extraction, its execution price must be sufficiently displaced from the correct oracle mark.
- There must be enough liquidity for the absolute loss to exceed the contest threshold.

The saturation condition depends on pool share denomination, token pair price, and bin share supply. Therefore, this is not an unconditional bug affecting every pool.

However, it is not based on a malicious custom extension or a stale/malicious oracle. It occurs inside the protocol's first-party stop-loss extension with valid pool values, and no invariant at pool creation or extension initialization guarantees that metrics remain below the clamp.

Pool creators and LPs may choose different share denominations without changing the economic purpose of the pool. A percentage stop-loss should not silently stop working merely because the same economic value is represented by fewer shares.

## Why README oracle assumptions do not invalidate the finding

The direct-loss PoC never changes the oracle price after watermark initialization. The quote is correct, fresh, and identical before and during the attacker swap.

The vulnerability arises entirely from truncating two distinct, correctly computed `uint256` values to the same `uint104` ceiling. It is unrelated to oracle staleness, round completeness, updater availability, or incorrect off-chain data.

## Recommendation

Do not clamp a percentage-comparison metric before storing and comparing its high watermark.

Preferred fix:

- store both high watermarks as full-width `uint256` values;
- calculate and compare the full `uint256` metrics already produced by `_metrics()`;
- keep `lastDecayTs` in a separate packed slot if necessary.

Alternative designs:

- store each watermark as a mantissa plus an explicit shared exponent and normalize the current metric to the same exponent before comparison;
- store a per-bin scale factor that preserves relative changes without saturation;
- reject pool/extension configurations that can exceed the metric range for every permitted oracle price, although this is difficult to enforce safely when providers and prices can change.

Failing closed by reverting whenever a metric exceeds `uint104.max` would prevent the bypass, but it would turn saturation into a swap DoS. Preserving the full metric is preferable.

Add regression tests that:

- initialize a watermark above `uint104.max`;
- reduce the true metric by more than `drawdownE6` while keeping it above `uint104.max`;
- verify the relevant swap direction reverts;
- cover both `metricT0` and `metricT1` saturation;
- fuzz factory-valid per-share densities, share supplies, and oracle prices around the saturation threshold.
