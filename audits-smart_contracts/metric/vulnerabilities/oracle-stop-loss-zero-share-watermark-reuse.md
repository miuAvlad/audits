# Empty bins retain stop-loss watermarks and poison unrelated future liquidity

## Severity

Medium candidate

`OracleValueStopLossExtension` stores high watermarks by `(pool, binIdx)` but never resets them when a bin's total share supply reaches zero. A later, economically unrelated liquidity epoch in the same bin inherits the old epoch's watermark.

After a normal oracle movement, an attacker can reopen the empty bin with minimum liquidity whose live metric is below the inherited floor. The dust position then acts as a false one-way stop-loss barrier and blocks swaps from reaching materially larger liquidity in downstream bins.

The attack is permissionless after a bin has completed a zero-share transition. Liquidity removal remains available and an admin can eventually reset the watermark, so High is not justified.

The vulnerability does not depend on the timelock: stale watermark reuse and the false barrier occur for every timelock value. The timelock only determines how quickly the pool admin can apply the targeted watermark reset after the problem occurs.

## Affected code

- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol:40`
- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol:236-241`
- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol:267-284`

## Root cause

Watermarks outlive the share supply whose value they measured:

```solidity
mapping(address pool => mapping(int8 binIdx => BinHighWatermarks))
  public highWatermarks;
```

After each swap, the extension loads the current share supply and skips an empty bin:

```solidity
uint256 totalShares = PoolStateLibrary._decodeBinTotalShares(shares[i]);
if (totalShares == 0) continue;
```

Skipping does not delete or checkpoint `highWatermarks[pool][binIdx]`. There is also no liquidity hook that associates a watermark with a share-supply epoch.

The next time liquidity is added to that bin, `_checkAndUpdateWatermarks` compares its new value per share against the old epoch's high watermark:

```solidity
(uint256 hwm0, bool breach0) = _applyWatermark(
    metricT0,
    _decayed(hwmS.token0, decayRate, dt),
    floorMultiplier
);

if (breach0 && zeroForOne) revert OracleStopLossTriggered(...);
```

No storage field distinguishes:

```text
old LP epoch -> totalShares = 0 -> new LP epoch
```

The percentage comparison is therefore made between values belonging to different owners and different reserve compositions.

## Permissionless false-barrier flow

The integration PoC uses correct oracle observations and standard pool operations:

1. Bin `1` contains token0 liquidity and records `metricToken0 = 1,000,000` as its high watermark.
2. All bin `1` shares are removed, so both its reserves and total shares become zero.
3. The watermark remains `1,000,000`.
4. While bin `1` is empty, normal swaps move the cursor above it.
5. The correct oracle price increases by 20%.
6. An attacker reopens bin `1` below the cursor with only `minimalMintableLiquidity = 1,000` shares. The new epoch is token1-sided and its token0-denominated metric is approximately `833,333`.
7. With a 5% drawdown, the inherited threshold is approximately `950,000`.
8. A `zeroForOne` swap that crosses bin `1` now reverts, even though the new LP epoch never lost value.
9. Honest liquidity in downstream bin `-1` is unreachable in that direction.

The PoC isolates the stale epoch state: downstream bin `-1` has never been observed and has a zero watermark, so removing the dust barrier is sufficient for the same route to proceed.

## Economic asymmetry

In the demonstrated state:

```text
stale token0 watermark:       1,000,000
inherited 5% floor:             950,000
new epoch live metric:          833,333
attacker barrier shares:          1,000
blocked downstream token1:      100,000 tokens
```

The barrier cost is the raw amount required to mint the minimum shares, while the amount blocked is determined by all liquidity behind that bin. The attacker does not need to own or compromise the downstream LP position.

## Duration

With zero decay, the false barrier lasts until one of the following occurs:

- the oracle/bin composition moves the metric back above the inherited threshold;
- the pool admin executes a watermark/configuration change; or
- the attacker removes the barrier position.

With the realistic test rate `decayPerSecondE8 = 58` (approximately 5% per day), the inherited threshold remains breached after two days and clears around day three. The PoC uses the first-party representative `3 days` timelock from `test_initialize_setsConfig()`. Under that valid configuration, the admin can propose a targeted watermark reset immediately but cannot execute it before the full three-day delay. Lowering the timelock, changing drawdown, or changing decay is also governed by the current timelock and therefore cannot provide a faster emergency path.

Setting a nonzero timelock is not the misconfiguration that creates the barrier. Timelocking stop-loss changes is an explicit design feature intended to let LPs react to admin changes. The root cause is that a new liquidity epoch inherits an economically unrelated watermark; the timelock only delays administrative recovery from that state.

This can overlap with the separate decay-rounding issue: allowed-direction touches can checkpoint decay and prolong a barrier when each interval's decay rounds down. That is an impact amplifier, not the root cause of this finding.

## Proof of concept

The PoC is in:

```text
metric-periphery/test/extensions/OracleValueStopLossZeroShareEpoch.audit.t.sol
```

Run:

```bash
cd metric-periphery
forge test --match-path test/extensions/OracleValueStopLossZeroShareEpoch.audit.t.sol -vv
```

Observed tests:

```text
[PASS] test_staleWatermarkBlocksACompletelyNewLiquidityEpoch()
[PASS] test_realisticDecayLeavesTheFalseBarrierForMultipleDays()
```

Representative logs:

```text
stale HWM:                 1000000
attacker barrier cost:     1000
downstream blocked token1: 100000000000000000000000
```

## Why this is not intended stop-loss behavior

Blocking a direction after an actual drawdown of the currently exposed LP liquidity is intended. Here, the currently exposed position has no historical high and has suffered no drawdown. The extension compares it to value recorded for a fully withdrawn position.

Keeping a watermark while some original shares remain may prevent withdrawal/redeposit games. That rationale no longer applies once `totalShares == 0`: there are no protected claims left in the old epoch, and future LPs are unrelated to the historical value baseline.

## README assumptions

The finding does not require stale or incorrect oracle data. The 20% movement in the PoC is a correct market update. It also does not require a malicious pool admin or custom extension.

It does require a specific but reachable state transition: a previously observed bin becomes fully empty and is later reopened. The attack transaction and the minimum-liquidity barrier are permissionless.

## Recommendation

Make watermark lifetime follow liquidity-epoch lifetime.

Preferred approaches:

- invoke the extension on liquidity changes and delete both watermarks when a bin's total shares transition from nonzero to zero; or
- store a per-bin liquidity epoch counter in the pool and bind each watermark to that epoch, treating an epoch mismatch as an uninitialized watermark.

When the first liquidity of a new epoch is added, initialize its baseline from that epoch's own balances and the current oracle mark. Do not compare it against a prior zero-share epoch.

Add regression tests covering:

- nonzero shares -> zero shares -> nonzero shares;
- reopening on either side of the cursor;
- both swap directions;
- oracle movement while the bin is empty;
- zero and nonzero decay;
- downstream liquidity much larger than the reopened barrier.
