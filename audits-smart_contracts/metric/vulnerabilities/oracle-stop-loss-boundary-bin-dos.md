# Oracle stop-loss checks boundary-only bins and can cause one-way swap DoS

## Severity

Medium

This is primarily a liveness/griefing issue, not a direct fund-drain. The exploit path is permissionless once a pool has deployed the extension with drawdown enabled. The integration PoC shows a normal swap can prime the adjacent boundary bin watermark, then a 1-unit exact-input swap with zero deltas can park the cursor behind a one-way stop-loss barrier. With zero decay, the blocked direction remains closed after 30 days in the PoC. The severity can increase for pools with meaningful TVL, zero or slow watermark decay, strict drawdown configuration, and admin timelocks that make recovery slow.

## Summary

`OracleValueStopLossExtension` checks every bin between the initial and final pool cursor inclusively after a swap. However, `MetricOmmPool` can finalize a swap at the boundary of the next bin even when no liquidity from that final bin was actually traded.

Because the stop-loss check is direction-aware, a permissionless swap can move the pool cursor into a boundary-only bin using the direction that is not blocked, then leave the pool in a state where the opposite direction reverts because the same boundary bin is now included in the checked range.

No privileged action is needed by the attacker. The required high watermark can be created by normal prior swaps that touch or boundary-include the bin, because `_checkAndUpdateWatermarks()` automatically ratchets a bin watermark upward when the live metric is greater than the stored watermark.

## Affected code

- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol`
  - `afterSwap()`
  - `_afterSwapOracleStopLoss()`
  - `_checkAndUpdateWatermarks()`
- `metric-core/contracts/MetricOmmPool.sol`
  - swap bin-crossing logic in the token1-for-token0 and token0-for-token1 paths

## Root cause

The extension infers "touched bins" from the cursor movement:

```solidity
int8 lo = s0.curBinIdx < s1.curBinIdx ? s0.curBinIdx : s1.curBinIdx;
int8 hi = s0.curBinIdx > s1.curBinIdx ? s0.curBinIdx : s1.curBinIdx;
uint256 count = uint256(int256(hi) - int256(lo) + 1);
```

It then checks all bins in `[lo, hi]`, including the final bin.

This does not always match the bins that actually had swap deltas. In the pool, when a swap reaches a bin boundary, the cursor can be advanced into the next bin:

```solidity
curBinIdxCache++;
curPosInBinCache = 0;
```

For the opposite direction:

```solidity
curBinIdxCache--;
curPosInBinCache = type(uint104).max;
```

Those states can mean "the next bin was entered at its edge", not "the next bin's liquidity was consumed".

## Impact

An attacker can potentially create a one-way DoS around a stop-loss boundary.

In this finding, the precondition is not a stale oracle or a compromised admin. It is simply the extension's normal stop-loss state: a bin has a previously recorded high watermark, and its current live metric is below the allowed drawdown floor for one direction. That can happen under correct oracle prices because watermarks are high-water marks: after the bin is checked at a favorable price or balance composition, later market movement, swaps, liquidity changes, or slow/zero decay can make the current metric lower than the stored floor.

Assume bin `i + 1` has non-zero total shares and a previously recorded token0 high watermark created by normal prior pool activity. Its current `metricT0` is below the stop-loss threshold, so `zeroForOne` swaps would revert if that bin is checked.

1. The pool starts in bin `i`.
2. The attacker performs a `!zeroForOne` swap sized to end exactly at the boundary of bin `i + 1`.
3. The pool finalizes with `curBinIdx = i + 1` and `curPosInBin = 0`.
4. No liquidity from bin `i + 1` necessarily had to be traded.
5. The extension still checks bin `i + 1` because the range is inclusive.
6. Since only the token0-side stop-loss condition is active, and the attacker's swap direction is `!zeroForOne`, the check does not revert.
7. The pool is now parked at the boundary of bin `i + 1`.
8. Later `zeroForOne` swaps can revert because bin `i + 1` is included in the initial/final checked range and its `metricT0` remains below the high-watermark floor.

This can block one direction of swaps until the watermark decays enough or the correct oracle price moves favorably. If decay is zero or very slow, the practical recovery path may be a pool-admin configuration update, but no pool-admin action is required to trigger the griefing state.

## Concrete PoC

A real integration PoC was added at `metric-periphery/test/extensions/OracleValueStopLossBoundaryDoS.t.sol`. It uses the real pool, real ERC20 callback flow, and the real `OracleValueStopLossExtension`.

The PoC flow is:

1. Deploy a pool with `OracleValueStopLossExtension` configured as an `afterSwap` hook, `drawdownE6 = 50_000`, and `decayPerSecondE8 = 0`.
2. Add liquidity to bins `0` and `1`. Both bins initially contain token0.
3. A normal `!zeroForOne` exact-output swap consumes bin `0` and advances the cursor to `curBinIdx = 1`, `curPosInBin = 0`. Because the extension checks `[0, 1]` inclusively, bin `1` receives a token1 high watermark even though it was only boundary-included and not traded through.
4. The oracle price moves down normally, making bin `1`'s token1-denominated metric fall below its high-watermark floor. This does not require a stale or incorrect oracle.
5. The attacker performs a `zeroForOne` exact-input swap of `1` unit. The swap has zero token deltas, but it moves the cursor from bin `1` at position `0` to bin `0` at `type(uint104).max`. Bin `1` balances remain unchanged.
6. A later `!zeroForOne` swap from another user reverts with `OracleStopLossTriggered` because crossing upward checks bin `1` inclusively.
7. With decay disabled, the same blocked direction still reverts after `30 days`.

Run it with:

```bash
cd metric-periphery
forge test --match-path test/extensions/OracleValueStopLossBoundaryDoS.t.sol -vvv
```

## Duration of the blocked state

The blocked direction remains blocked while the checked bin live metric is below the decayed high-watermark floor for that direction. Decay is lazy: failed swaps revert without updating storage, but the next check still computes decay from elapsed time.

If `decayPerSecondE8 > 0`, the block can self-clear after enough time, because `_decayed()` lowers the stored high watermark used for the next comparison. If `decayPerSecondE8 == 0`, and the oracle price/bin metric does not recover, the directional block can last indefinitely.

Moving the cursor in the still-allowed direction may move activity away from the boundary, but crossing back through the problematic bin in the blocked direction remains gated by the same stop-loss check. In that case the bin behaves like a one-way barrier until decay, metric recovery, or admin reconfiguration clears the condition.

## Permissionless attack path

The attacker does not need to control the pool admin, oracle, extension, or LP positions.

The only required attacker capability is to call `swap()` with an amount and direction that moves the pool cursor to the boundary of a bin whose live metric is below the high-watermark floor for the opposite direction. Because swaps are public, the griefing transaction itself is permissionless.

The high-watermark floor condition can arise from normal operation:

1. Any previous swap that includes the bin can initialize or ratchet the bin watermark upward.
2. Later price movement or pool balance changes can make the live metric fall below the drawdown threshold.
3. The attacker then uses the still-allowed direction to park the cursor at that bin boundary.
4. The opposite direction becomes blocked for later users because the boundary-only bin is included in the stop-loss range.

## Additional watermark state issue

The extension also updates watermark state for every checked bin:

```solidity
hwmS.token0 = uint104(hwm0);
hwmS.token1 = uint104(hwm1);
hwmS.lastDecayTs = uint32(block.timestamp);
```

This means a boundary-only bin can have its watermark decayed, ratcheted, or timestamp-refreshed even though no swap liquidity was consumed from that bin. A permissionless caller can therefore influence stop-loss state for adjacent bins merely by landing swaps on bin boundaries.

## Why this is worse than a simple false positive

The issue is not only that an exact-boundary swap may revert. The more useful attack shape is that the attacker can use the allowed direction to move the active cursor into a problematic boundary bin, after which the opposite direction becomes blocked for other traders.

This makes the finding a pool-level liveness issue rather than only a bad edge-case UX issue.

## Preconditions

- The pool uses `OracleValueStopLossExtension`.
- Stop-loss drawdown is enabled.
- The target boundary bin has `totalShares > 0`.
- The target bin's live metric is below the high-watermark floor for one side, due to normal prior pool activity, while the attacker's direction is the opposite direction that does not revert on that condition.
- The attacker can size a swap to land on or cross into the boundary bin.

## Recommendation

Do not infer the checked stop-loss bins only from initial and final cursor indexes.

Preferred fix:

- Pass actual swapped-bin information to the extension, such as the bins that emitted non-zero `BinSwapped` deltas, and only apply stop-loss checks to bins whose balances were affected by the swap.

Alternative partial fix:

- Exclude boundary-only final bins:
  - if the swap moved upward and final `curPosInBin == 0`, exclude the final bin;
  - if the swap moved downward and final `curPosInBin == type(uint104).max`, exclude the final bin.

The partial fix should be treated carefully because rounding can produce very small trades that do not materially move `curPosInBin`. Passing explicit touched-bin/delta data is cleaner and less ambiguous.

## Implemented PoC

Implemented in `metric-periphery/test/extensions/OracleValueStopLossBoundaryDoS.t.sol`. The PoC proves both the permissionless one-way DoS and the long-lived blocked state when `decayPerSecondE8 == 0`.

Is it intended design? the purpose of the extension is to block swaps in directions
Should be somehow presented as a false positiv that blocks the swap