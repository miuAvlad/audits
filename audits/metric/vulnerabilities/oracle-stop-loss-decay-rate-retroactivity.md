# Decay-rate changes retroactively rewrite every idle bin's stop-loss history

## Severity

**Medium candidate**

An ordinary, timelocked change between two valid decay configurations can either erase active protection or create a false directional swap stop. The problem does not require an incorrect/stale oracle or a malicious pool administrator; it occurs because the newly selected rate is applied to time that elapsed before the configuration became active.

## Summary

`OracleValueStopLossExtension` stores one `lastDecayTs` per bin, but only one current `decayPerSecondE8` per pool. Executing a decay-rate update changes the global rate without checkpointing any bin.

The next read or swap computes:

```text
decayedHwm = storedHwm - storedHwm * newRate * (now - lastDecayTs) / 1e8
```

The entire interval since the bin's last swap is therefore evaluated using the **new** rate, including time during which the old rate was active.

This breaks in both directions:

- **Increasing the rate** retroactively consumes old time and can instantly reduce an active watermark to zero. A subsequent loss is treated as the first observation of a new epoch and is adopted as the new watermark.
- **Decreasing the rate** recomputes old time with less decay and can resurrect watermark value that had already decayed under the former policy. Setting the new rate to zero can make the resulting false directional stop persist indefinitely absent admin repair.

## Root cause

[`OracleValueStopLossExtension.sol`](../metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol#L139-L146) only replaces the pool-wide rate:

```solidity
function executeOracleStopLossDecay(address pool_) external onlyPoolAdmin(pool_) {
  PoolStopLossSchedule storage sched = _initializedSchedule(pool_);
  if (sched.pendingDecayExecuteAfter == 0) revert OracleStopLossNoPendingDecay(pool_);
  _requireElapsed(sched.pendingDecayExecuteAfter);
  uint32 decay = sched.pendingDecayPerSecondE8;
  oracleStopLossConfig[pool_].decayPerSecondE8 = decay;
  (sched.pendingDecayPerSecondE8, sched.pendingDecayExecuteAfter) = (0, 0);
  emit OracleStopLossDecaySet(pool_, decay);
}
```

No rate epoch or cumulative decay index is stored. Later, [`_checkAndUpdateWatermarks`](../metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol#L267-L284) combines the old bin timestamp with the new rate:

```solidity
uint256 dt = block.timestamp - hwmS.lastDecayTs;
(uint256 hwm0, bool breach0) =
  _applyWatermark(metricT0, _decayed(hwmS.token0, decayRate, dt), floorMultiplier);
```

The view path has the same problem, so the state discontinuity is visible immediately after execution even before another swap.

## Concrete false-DoS example

The PoC uses the extension's documented realistic rate and a correct oracle move:

```text
initial HWM:                         1,000,000
old decayPerSecondE8:                       58  (~5% per day)
elapsed under old policy:                 3 days
correctly decayed HWM:                 849,664
5% floor under old policy:             807,180
live metric after correct +20% oracle: 833,300  (allowed)
new decayPerSecondE8:                         0
HWM immediately after execution:     1,000,000
new/resurrected 5% floor:               950,000
same live metric:                        833,300  (blocked)
```

Immediately before execution, `833,300 >= 807,180`, so the route is valid under the policy that actually governed the elapsed three days. Immediately after execution, the stored HWM is recomputed as if those three days had always used zero decay. It jumps back to `1,000,000`, and the same correct oracle state now triggers `OracleStopLossTriggered`.

Because the newly configured rate is zero, waiting one year does not change the false barrier. Recovery requires another admin/timelocked configuration action or a manual per-bin watermark reset.

## Concrete protection-erasure example

A second PoC uses a bounded production-pool scenario:

- old decay is nonzero (`1`, approximately 0.0864% per day);
- new decay is the documented `58` (approximately 5% per day);
- only two days elapse: one before proposal and the one-day timelock;
- drawdown is 0.5%, the 100,000-token0 bin is 5% below the oracle midpoint, and only 50% of its inventory is purchased;
- the oracle has a 10 bps bid/ask spread, while the pool charges a 5 bps spread fee and a 5 bps notional fee.

At execution:

```text
initial genuine HWM:                         999,999
HWM before proposal after one day:           999,136
HWM after two days if the old active rate
were correctly checkpointed at execution:    998,272
new decayPerSecondE8:                              58
actual HWM immediately after execution:       899,776
```

The implementation applies `58` to both historical days even though it becomes active only at execution. A control that keeps the actually active old rate for those same two days retains an HWM of `998,272` and rejects the trade.

### Why this is not simply a swap under the new rate

At the execution timestamp, zero seconds have elapsed under rate `58`. The parameter is a per-second decay velocity, so a correct transition must settle elapsed time under the rate that governed that time before activating the new rate:

```text
T0: watermark established; rate 1 is active
T1: rate 58 proposed; rate 1 remains active during the timelock
T2: update executed; rate 1 has governed the entire T0 -> T2 interval
T2 onward: rate 58 begins governing newly elapsed time
```

The correct HWM at `T2` is therefore `998,272`. The implementation first stores `58`, then the next read uses `T2 - T0` with that new rate and returns `899,776`. This grants approximately two days of rate-58 decay immediately, before rate `58` has governed even one second.

The subsequent swap is legitimately evaluated after the update, but its abnormally low threshold comes from fictitious pre-activation decay. A normal swap under rate `58` would begin from the correctly settled `998,272` HWM and accrue faster decay only as time passes after `T2`. At rate `58`, roughly 8.7 hours of post-execution decay would be required before the tested `975,248` metric became permissible. The faulty transition makes that extraction available in the execution block.

### Documentation assessment

The repository does not explicitly state whether a rate update is prospective or whether the new rate should reprice the watermark's entire historical age. The first-party NatSpec describes “linear watermark decay per second,” calls `58` approximately 5% “per day,” and guarantees that value cannot fall faster than `drawdown + decay * t`. It also calls the executed value the “new” decay rate. This language favors treating the parameter as a time-dependent rate that governs time after activation.

There is no documentation saying that executing a rate update intentionally recalculates pre-activation time. Manual watermark replacement explicitly says it resets the bin's decay clock, while decay-rate execution neither resets nor documents any effect on historical time.

The official `test_decayTimelockZeroExecutesImmediately` only verifies that the stored config changes to `58`. Other official decay tests configure one fixed rate before establishing a watermark. No first-party test establishes a watermark, lets time pass under one rate, changes the rate, and asserts the resulting HWM.

The repository supports prospective semantics but does not define the transition conclusively. The team acknowledged the observed repricing and pointed to the timelock exit window and the admin ability to choose the maximum rate. The root behavior is therefore not disputed; contest validity turns on whether the incremental loss under an ordinary selected rate exceeds those controls.

### LP balance-sheet loss

The pool begins the attack transaction with approximately 100,000 token0 in the affected bin. Holding the authenticated oracle bid constant, the bin's token1-denominated principal changes as follows:

```text
LP value before at authenticated bid:  99,949.999999950974761401
LP value after at authenticated bid:   97,499.988746669696475182
LP principal loss:                        2,450.011253281278286219
```

The trader buys 50% of the inventory and can hedge it at the same unchanged authenticated bid:

```text
token0 received:                          50,000.000000000000000000
authenticated external bid:                   0.9995 token1/token0
output value at that bid:                 49,974.999999999999999479
token1 paid, including configured fees:   47,548.751247031221738272
trader profit at the bid:                    2,426.248752968778261207
LP loss minus trader profit:                  23.762500312500025012
```

The LP loss is therefore an actual reduction in assets held by the bin at the unchanged oracle mark. The trader captures most of it; the approximately `23.76` difference is value routed outside the LP bin through fees and integer rounding. No oracle movement is used between the before and after valuations.

### Conservative bug-attributable loss

The full `2,450.01` loss should not be attributed entirely to the defect because the configured policy intentionally permits a 0.5% one-time drawdown plus decay accumulated under the active old rate. The correct comparison is:

```text
metric before:                                      999,999
correct HWM after two days at old rate 1:            998,272
correct 0.5% drawdown-plus-decay floor:              993,280
post-swap metric accepted after faulty transition:   975,248
loss beyond the correct policy floor:                 18,032
excess as a fraction of initial metric:              1.8032% (180.32 bps)
total excess value for this 100,000-unit bin:        1,803.2 token1
```

The identical transaction reverts with `OracleStopLossTriggered` when the historical interval is evaluated using the rate that was actually active. After execution rewrites that interval using `58`, the transaction succeeds and the already-depleted metric `975,248` is adopted as the new watermark. Conservatively, the finding claims the `1,803.2` token1 / `180.32 bps` excess beyond the documented policy, not the entire arbitrage amount.

### Why this is not merely ordinary arbitrage

The core pool intentionally permits bins to quote away from the oracle, so the existence of an arbitrage opportunity is not itself the vulnerability. Arbitrage is only the mechanism by which the LP's oracle-marked value is extracted.

The extension separately documents that value per share at oracle marks cannot fall faster than the configured drawdown plus elapsed decay. The rate transition violates that guarantee by applying a rate before its activation time. The same pool state, oracle prices, swap amount, and fees are rejected with correct history and accepted with rewritten history.

The direct economic amount depends on pool inventory and bin configuration, but the PoC clears the contest's 0.01% and 10-unit thresholds using a 100,000-unit bin. The state-history corruption itself affects every untouched bin whenever the rate changes.

## Permission and configuration analysis

The pool admin is not acting maliciously in either path:

- `0`, `1`, and `58` all pass the contract's documented bounds;
- the update respects the configured timelock;
- changing decay is an explicit supported admin operation;
- the transition error affects bins whose `lastDecayTs` predates execution, regardless of who supplied their liquidity.

After the valid admin transition, any user can be the first swapper to exploit an erased watermark or encounter a resurrected boundary. The issue is not that the semi-trusted admin selected an out-of-range parameter; the accounting fails to preserve history when a supported parameter changes.

The admin could separately propose the maximum `1e8` rate, which intentionally zeros watermarks after the timelock. That authority does not make an announced `58` rate equivalent to the maximum: the PoC measures `1.8032%` of loss beyond the policy selected by the admin, and the same transaction reverts under correctly checkpointed history. However, LP withdrawal remains available throughout the timelock, and the extension NatSpec explicitly tells LPs to monitor at least as often as the timelock or trust the pool admin. This is the principal remaining Medium-severity objection.

## Impact

- A rate increase can silently weaken the stop-loss for untouched bins and expose LP inventory to losses beyond the documented drawdown-plus-decay bound.
- A rate decrease can unexpectedly block a direction even though the live metric was above the correctly elapsed threshold immediately before execution.
- A transition to zero decay makes the false stop non-self-healing.
- One global rate change affects every bin, while manual HWM recovery is per-bin and itself timelocked.

The rate-increase PoC records a total bid-valued LP principal loss of approximately `2,450.01` token1. Because part of that loss is intentionally permitted by the old drawdown-plus-decay envelope, the conservative amount attributed to the defect is the `1,803.2` token1 / `180.32 bps` excess beyond the correct policy floor. The trader captures approximately `2,426.25` token1 from the full transaction, but the report does not use that entire arbitrage profit as the severity numerator.

The core pool's displaced pricing is intentional; the violated security property is the extension's explicit oracle-marked value-loss guarantee. LP removal remains available and pool-admin repair exists, so High severity is not justified. A valid transition followed by permissionless extraction exceeding the contest's `0.01%` and `10`-unit thresholds supports Medium, although dependence on an economically executable displaced bin remains a judging risk.

## Proofs of concept

Rate increase and material accepted loss:

[`OracleValueStopLossDecayRateTransition.audit.t.sol`](../metric-periphery/test/extensions/OracleValueStopLossDecayRateTransition.audit.t.sol)

```bash
cd metric-periphery
forge test --match-path test/extensions/OracleValueStopLossDecayRateTransition.audit.t.sol -vv
```

Rate decrease, correct oracle move, and persistent false stop:

[`OracleValueStopLossDecayRateDecrease.audit.t.sol`](../metric-periphery/test/extensions/OracleValueStopLossDecayRateDecrease.audit.t.sol)

```bash
cd metric-periphery
forge test --match-path test/extensions/OracleValueStopLossDecayRateDecrease.audit.t.sol -vv
```

## Recommendation

Do not combine a historical bin timestamp with a newly selected rate. Use an epoch/cumulative-index design:

1. Maintain a pool-wide cumulative decay index and its last update timestamp.
2. Before changing the rate, advance the index to the execution timestamp using the old rate.
3. Store each bin's last observed index rather than relying only on a wall-clock timestamp.
4. On touch, apply only the index delta accumulated across the correct sequence of rate epochs.

With at most 256 bins, another option is to checkpoint every nonzero HWM at rate execution, but doing this in one transaction may be gas-heavy. A cumulative index avoids the loop and preserves piecewise rate history exactly.
