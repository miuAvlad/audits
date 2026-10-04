# Compounded provider spreads shift stop-loss valuation and allow profitable swaps beyond the configured drawdown

## Severity

Medium candidate

Once a pool is in the affected liquidity and cursor state, any user can execute the loss-making swap. The attack does not require a stale or incorrect oracle update, control of the pool admin, control of the oracle, or a privileged call during the exploit.

The strengthened end-to-end PoC uses the repository's common `0.01%` `marginStep`, its commonly tested `500,000` confidence parameter, a nonzero `0.05%` notional fee, and a `1%` stop-loss. A correct and fresh 200 bps oracle-spread observation shifts the extension mark by only `0.01` bps. That one-unit metric difference nevertheless makes the production check accept an atomic swap that the identical integer calculation at the raw oracle mark rejects. The attacker earns approximately `951.71` tokens after fees while the bin loses approximately `1,000.03` tokens.

The Medium argument is the atomic security-control bypass: the production hook allows a roughly `1%` principal-loss transaction that the documented raw-oracle-value check would revert completely. The main contest risk is that judges may count only the approximately `0.000033%` loss beyond the configured `1%` tolerance as bug-attributable impact. It is therefore not a clean Medium despite the material transaction-level loss.

## Summary

`MetricOmmPool` derives its internal midpoint as the geometric mean of the final provider quotes:

```solidity
midPriceX64 = Math.sqrt(bidPriceX64 * askPriceX64);
```

`OracleValueStopLossExtension` instead values every bin at the arithmetic mean:

```solidity
uint256 midPriceX64 = (uint256(bidPriceX64) + uint256(askPriceX64)) / 2;
```

An arithmetic midpoint is not inherently incorrect. If the final quotes are symmetric around a raw oracle price `P`, it reconstructs `P` correctly.

The problem is that the official price providers apply two spread controls sequentially:

1. They create `bid` and `ask` around the raw oracle midpoint using the oracle spread multiplied by `confidenceParam`.
2. They multiply those already-separated quotes by different `marginStep` factors.

When both controls are nonzero, the resulting arithmetic midpoint is no longer the raw oracle midpoint. Nevertheless, `OracleValueStopLossExtension` treats it as the oracle mark when calculating LP value.

The shift need not itself be large. It changes both the initialized high watermark and its floored drawdown threshold. An attacker can select an exact-output amount that lands exactly on the production threshold while falling below the threshold produced by the same metric math at the raw oracle mark. Since the hook executes after the swap and reverts atomically, this one-unit disagreement decides whether the entire loss-making swap succeeds.

## Affected code

- `metric-core/contracts/libraries/SwapMath.sol`
  - `midAndSpreadFeeX64FromBidAsk()`
- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol`
  - `_afterSwapOracleStopLoss()`
  - `_metrics()`
- Providers that compose confidence widening and `marginStep`, including:
  - `smart-contracts-poc/contracts/PriceProvider.sol`
  - `smart-contracts-poc/contracts/PriceProviderL2.sol`
  - `smart-contracts-poc/contracts/ProtectedPriceProvider.sol`
  - `smart-contracts-poc/contracts/ProtectedPriceProviderL2.sol`
  - the customizable shaped-quote path of `AnchoredPriceProvider.sol` when the shaped quote survives the band clamp

`PriceVelocityGuardExtension` also calls `SwapMath.midAndSpreadFeeX64FromBidAsk()` and therefore uses the pool's geometric midpoint, demonstrating that two first-party extensions interpret the same provider quotes using different marks.

## Root cause

Let:

```text
P = correct raw oracle midpoint
c = confidence-adjusted half-spread, expressed as a fraction
m = marginStep, expressed as a fraction
```

The provider first constructs a symmetric confidence band:

```text
bid0 = P * (1 - c)
ask0 = P * (1 + c)
```

It then applies `marginStep` independently to both sides:

```text
bid = P * (1 - c) * (1 - m)
ask = P * (1 + c) * (1 + m)
```

The extension's arithmetic midpoint is therefore:

```text
M_arithmetic
  = (bid + ask) / 2
  = P * ((1 - c)(1 - m) + (1 + c)(1 + m)) / 2
  = P * (1 + c*m)
```

The cross-term `c*m` shifts the value used by the stop-loss away from the correct oracle midpoint.

For comparison, the pool computes:

```text
M_geometric
  = sqrt(bid * ask)
  = P * sqrt((1 - c^2)(1 - m^2))
```

Thus the raw oracle midpoint, the pool midpoint, and the stop-loss midpoint can all differ:

```text
raw oracle mark:       P
pool curve anchor:     P * sqrt((1 - c^2)(1 - m^2))
stop-loss value mark:  P * (1 + c*m)
```

The provider interface only returns the final `bid` and `ask`. After both transformations have been applied, the stop-loss cannot reliably recover `P` from those two values.

## Why this permits value extraction

Consider a positive `marginStep`, so `M_arithmetic > P`, and a token1-heavy bin.

During a `zeroForOne` swap, the pool receives `x` token0 and sends `y` token1. The extension measures token0-denominated bin value as:

```text
V_extension = token0 + token1 / M_arithmetic
```

The correct value change at the raw oracle midpoint and the extension's measured change are:

```text
delta V_raw       = x - y/P
delta V_extension = x - y/M_arithmetic
```

Their disagreement is:

```text
delta V_extension - delta V_raw
  = y * (1/P - 1/M_arithmetic)
  > 0
```

Thus the extension always reports more remaining token0 value than exists at the raw oracle mark. At `q = y/x = M_arithmetic`, this reduces to the direct `x*c*m` blind spot described by the original PoC. More importantly, the attacker can combine even a small disagreement with the configured drawdown.

The production extension stores and checks integer metrics. In the strengthened PoC:

```text
raw-oracle metric before:      999999
production watermark before:  999998

raw-oracle 1% floor:           989999
production 1% floor:           989998

metric after the attack:       989998
```

The production comparison is strict `<`, so `989998` is accepted against the production floor. The raw-oracle control sees `989998 < 989999` and rejects. Both controls use the same `METRIC_SCALE`, `Math.mulDiv` rounding, balances, shares, and drawdown; only the valuation mark differs.

For a zero-for-one swap, the pool's effective execution price around cursor distance `d` is approximately:

```text
q = bid * (1 + d)
```

The strengthened PoC uses a valid `2.06%` cursor distance, which places execution approximately `1%` above the raw mark. The attacker then selects the exact output that lands on the production floor.

For a valid negative `marginStep`, the arithmetic midpoint is below `P`. The analogous loss occurs in the opposite swap direction against a token0-heavy bin.

## Permissionless attack path

1. A pool uses `OracleValueStopLossExtension` with a nonzero drawdown.
2. Its official provider has nonzero confidence widening and nonzero `marginStep`.
3. Normal pool activity or the pool's valid initial state places an outgoing-token bin at a profitable execution price above the raw mark.
4. The target bin contains inventory on the outgoing-token side.
5. A previous swap has initialized the bin watermark. The PoC deliberately initializes it with a separate dust swap so the result does not rely on a first-touch watermark issue.
6. The attacker submits an exact-output swap sized to land on the production stop-loss floor.
7. The attacker receives more value than it pays at the correct raw oracle midpoint.
8. The extension values the conversion at `M_arithmetic` and lands exactly on its accepted floor; the raw-oracle control is one unit below its floor and would revert.

No admin or oracle interaction is part of the exploit transaction.

## Concrete example

The PoC uses:

```text
raw oracle midpoint P:       1.0000
oracle spread input:         200 bps
confidenceParam:             500,000
confidence half-spread c:    1%
marginStep m:                0.01%
final bid:                   0.989901
final ask:                   1.010101
arithmetic midpoint:         1.000001
geometric midpoint:          approximately 0.999949994
cursor distance:             2.06%
configured drawdown:         1%
protocol notional fee:       0.05%
bin liquidity:               100,000 token1
inventory converted:         98.62%
```

The correct raw oracle midpoint is unchanged at `1.00`. The shifted arithmetic midpoint is:

```text
1.00 * (1 + 0.01 * 0.0001) = 1.000001
```

Observed end-to-end result:

```text
token0 paid by attacker:              97,668.286252596664792689
token1 received by attacker:          98,619.999999003649082257
attacker profit at raw 1:1 mark:      951.713746406984289568

raw bin value before:                 99,999.999999989707039401
raw bin value after:                  98,999.966785937157918820
raw LP loss:                          approximately 1.0000332%

configured stop-loss drawdown:        1%
raw metric before / after / floor:    999999 / 989998 / 989999
production HWM / metric / floor:      999998 / 989998 / 989998
production watermark after:           999998
```

The production check accepts equality at `989998`. Replacing only the valuation mark with the raw oracle midpoint produces floor `989999`, so the same final metric reverts. The attacker remains profitable after the nonzero notional fee.

## Proof of concept

The integration PoC is located at:

```text
metric-periphery/test/extensions/OracleValueStopLossMidMismatch.audit.t.sol
```

It uses:

- the real `MetricOmmPool` swap path;
- the real bin accounting and callback settlement;
- the real `OracleValueStopLossExtension` after-swap hook;
- the exact two-stage quote formula used by `PriceProvider`;
- a separately initialized watermark;
- an exact-output swap against real pool liquidity.

Run:

```bash
cd metric-periphery
forge test --match-path test/extensions/OracleValueStopLossMidMismatch.audit.t.sol -vvv
```

Observed result:

```text
[PASS] test_commonParamsShiftedMarkLetsOnePercentLossPass()
```

## Impact

A permissionless trader can extract value from LP inventory through a swap that violates the documented oracle-value drawdown limit. The strengthened PoC proves approximately `1,000.03` tokens of LP loss and `951.71` tokens of net attacker profit after a 5 bps notional fee.

The hidden value error around the shifted midpoint scales with:

```text
c * m * converted inventory
```

The strengthened path combines the mark error with the drawdown that the extension intentionally permits. An attacker selects a bin execution price and exact-output size that consume the production arithmetic-metric drawdown exactly. The shifted watermark lowers the production floor by one unit, while the equivalent raw-oracle floor remains one unit above the final metric. Because `afterSwap` is an atomic hook, this controls whether the complete transaction succeeds or reverts.

The severity caveat is attribution. A judge may consider only the excess beyond the intended drawdown to be caused by the bug. In the strengthened PoC, the raw loss is approximately `1.0000332%` against a `1%` limit, so the marginal excess is small even though the counterfactual transaction reverts completely. This objection prevents treating the finding as a clean Medium.

## Preconditions and limitations

- The pool must use `OracleValueStopLossExtension` with an active drawdown.
- Both confidence widening and `marginStep` must be nonzero. If either `c == 0` or `m == 0`, the cross-term disappears and the arithmetic midpoint reconstructs `P`.
- The affected bin must hold sufficient outgoing-token inventory.
- A correct oracle-spread observation must be nonzero. The PoC uses a 200 bps observation, which is plausible for volatile assets but not routine for highly liquid stable pairs.
- The cursor must place the affected bin at a profitable execution price. The PoC uses a valid `2.06%` distance.
- The absolute loss must exceed the contest threshold, which depends on liquidity size and the provider parameters.

The provider configuration itself is ordinary: `confidenceParam = 500,000` and `marginStep = 0.01%` are the values repeatedly used by the repository's provider tests. The PoC also charges a nonzero `0.05%` notional fee and uses a `1%` drawdown. No out-of-bounds parameter or malicious trusted-party action is required.

The 200 bps oracle spread and exact threshold alignment remain market-state preconditions. Larger valid `marginStep` or confidence values produce a larger direct blind spot, but relying on them reintroduces a configuration objection. High is not defensible.

## Why the correct-oracle assumption does not invalidate the finding

The PoC assumes the oracle midpoint, spread, and timestamp are all correct and fresh.

The finding does not claim that the oracle returned a stale or incorrect value. The error occurs after the correct oracle observation is received:

1. the provider composes confidence and margin factors;
2. the extension reconstructs a midpoint from the transformed quotes;
3. that reconstructed midpoint differs from the correct raw oracle midpoint by `P*c*m`;
4. LP value is checked against the shifted midpoint.

Therefore, the README assumption that oracle updates are correct and non-stale does not remove this path.

## Why this is not simply an arithmetic-versus-geometric-mean bug

Blindly replacing the arithmetic mean with the geometric mean is not necessarily correct.

If `marginStep == 0`, the provider returns:

```text
bid = P * (1 - c)
ask = P * (1 + c)
```

In that case:

```text
arithmetic mean = P
geometric mean  = P * sqrt(1 - c^2)
```

The arithmetic mean is the correct economic oracle mark for a symmetric confidence band. Using the geometric mean for value accounting would make the mark move merely because confidence widened.

The actual root cause is that the extension receives only post-transformation bid/ask values and assumes their arithmetic mean remains the raw oracle mark after sequential asymmetric multiplication. It does not.

## Recommendation

Preferred fix:

1. Expose the canonical raw oracle midpoint alongside `bid` and `ask` in the provider interface.
2. Pass that canonical midpoint through the pool's extension context.
3. Use it in `OracleValueStopLossExtension` for LP value accounting.

This preserves the distinction between:

- the raw economic oracle mark used to value LP inventory;
- the geometric curve anchor used by pool swap math;
- the final bid/ask execution envelope.

Alternative fix:

- Compose confidence and margin into one symmetric half-spread around `P`, with outward rounding, so that `(bid + ask) / 2` remains equal to `P`.

Do not switch to the geometric midpoint without first defining which mark the stop-loss is intended to protect. If the protocol intentionally wants the geometric pool anchor instead of the raw oracle midpoint, use the shared `SwapMath.midAndSpreadFeeX64FromBidAsk()` helper consistently and update the extension documentation and invariants accordingly.

Add regression tests where:

- `bid != ask`;
- both `confidenceParam` and `marginStep` are nonzero;
- a watermark is initialized before the attack swap;
- raw oracle value falls beyond `drawdownE6` while the extension must revert;
