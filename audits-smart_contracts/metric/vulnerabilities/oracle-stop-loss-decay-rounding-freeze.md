# Zero-delta swaps can reset watermark decay and indefinitely freeze one swap direction

## Severity

Medium

This is a permissionless liveness/griefing issue rather than a direct fund drain. A caller can prevent the configured nonzero watermark decay from accumulating and keep one of the pool's two swap directions unavailable for as long as the legitimate drawdown condition persists.

The integration PoC uses the extension's documented `decayPerSecondE8 = 58`, a 5% drawdown, a realistic stablecoin/BTC-wrapper price ratio, approximately one million stablecoin units of liquidity, and a correct oracle repricing. One zero-delta call per day keeps a one-token1 victim swap blocked for 30 days at zero token cost. Without those calls, the same swap recovers after three days.

The attacker still pays gas, the opposite swap direction remains available, and a favorable oracle move or active admin recovery can clear the condition. Medium is therefore more defensible than High.

## Summary

`OracleValueStopLossExtension` implements lazy linear decay by calculating an integer decrement from the time since `lastDecayTs`:

```solidity
return hwm - (hwm * factor) / E8;
```

After every permitted `afterSwap` check, it writes `lastDecayTs = block.timestamp`, even if the calculated decrement rounded to zero:

```solidity
hwmS.token0 = uint104(hwm0);
hwmS.token1 = uint104(hwm1);
hwmS.lastDecayTs = uint32(block.timestamp);
```

Consequently, a caller can checkpoint the watermark often enough that every individual decay interval is smaller than one integer unit. Each interval's fractional decay is discarded, while the timestamp from which the next interval is measured is advanced.

The pool makes this especially cheap because it accepts a nonzero requested swap amount whose realized token deltas are both zero, then still invokes `afterSwap`. Such a call transfers no tokens and does not move the pool cursor, but it refreshes the extension's decay clock.

## Affected code

- `metric-periphery/contracts/extensions/OracleValueStopLossExtension.sol`
  - `_checkAndUpdateWatermarks()` at lines 258-285
  - `_decayed()` at lines 318-324
- `metric-core/contracts/MetricOmmPool.sol`
  - `swap()` only rejects an exactly zero requested amount at line 225
  - `afterSwap` hooks are invoked unconditionally after execution at lines 280-295

## Root cause

For watermark `H`, decay rate `r`, and elapsed interval `dt`, the stored decrement is:

```text
decrement = floor(H * r * dt / 1e8)
```

If:

```text
H * r * dt < 1e8
```

the decrement is zero. Nevertheless, `_checkAndUpdateWatermarks()` resets `lastDecayTs` to the current timestamp. Repeating a permitted call before a full integer decrement accrues therefore produces:

```text
H -> H -> H -> H ...
```

instead of allowing the fractional decay from multiple intervals to accumulate.

This affects a breached watermark because blocking is direction-aware. In the PoC, the token1-denominated watermark is breached, so `zeroForOne == false` swaps revert. A `zeroForOne == true` call is still allowed; it processes the same breached token1 watermark, preserves it, and advances its timestamp.

The same `lastDecayTs` is shared by both token watermarks in the bin, which makes the timestamp refresh apply to both sides.

## Why this is unintended

The blocked state itself is normal stop-loss behavior; preventing the configured recovery is not.

The contract-level documentation states that watermarks decay linearly and describes the ongoing guarantee as `drawdown (one-time) + decay * t`. The repository also contains `test_decayRearmsAfterPermanentRepricing()`, which deliberately applies a permanent repricing, waits for decay, and expects the previously blocked direction to become callable again.

Under the attack, the oracle state and elapsed wall-clock time are identical to that intended recovery scenario. The only difference is economically empty activity in the opposite direction. Thirty zero-delta calls change the outcome from recovery to continued reversion, showing that elapsed decay incorrectly depends on how often a public caller checkpoints the bin.

## Concrete arithmetic

The PoC reaches the following values:

```text
token1 high watermark H:            19
decayPerSecondE8 r:                 58
attacker interval dt:               86,400 seconds
drawdownE6:                          50,000 (5%)
live token1 metric after repricing: 16
```

For one day:

```text
floor(19 * 58 * 86,400 / 1e8)
= floor(95,212,800 / 100,000,000)
= 0
```

The attacker call therefore stores the same watermark `19` and resets the clock. Its 5% floor remains:

```text
floor(19 * 950,000 / 1e6) = 18
```

The victim swap's post-swap metric is `17`, so it remains below `18` and reverts.

Without attacker calls, three days accrue in one interval:

```text
floor(19 * 58 * 259,200 / 1e8)
= floor(285,638,400 / 100,000,000)
= 2
```

The watermark becomes `17`, and its floor becomes:

```text
floor(17 * 950,000 / 1e6) = 16
```

The same victim swap then succeeds.

## Permissionless attack path

1. A pool uses the first-party `OracleValueStopLossExtension` with a functional drawdown and nonzero decay.
2. Normal trading initializes a per-bin high watermark.
3. A correct oracle repricing causes the token1 metric to fall below its drawdown floor. This legitimately blocks the `zeroForOne == false` direction initially.
4. The configured decay would naturally re-arm that direction after enough uninterrupted time.
5. Before an integer unit of decay accrues, the attacker calls a swap in the still-allowed `zeroForOne == true` direction with a one-raw-unit exact input.
6. Pool rounding produces `amount0Delta = 0` and `amount1Delta = 0`. No token is transferred and the cursor does not move.
7. The pool nevertheless invokes the extension's `afterSwap` hook.
8. Decay rounds to zero, but the extension stores `lastDecayTs = block.timestamp`.
9. The attacker repeats the call once per day. The token1 watermark never decays and victim swaps in the opposite direction continue to revert.

There is no finite inventory or cursor budget for this maintenance path because every demonstrated call has zero deltas and zero cursor movement. The attacker only pays transaction gas.

## Realistic PoC configuration

The integration test uses:

```text
drawdownE6:                    50,000 = 5%
decayPerSecondE8:              58, documented as approximately 5% per day
initial token1/token0 mark:    0.00002
repriced mark:                 0.000016, a correct 20% market move
liquidity shares:              1e24
initial token0 liquidity:      1,000,000 token0
post-prime token1 liquidity:   approximately 5 token1
victim exact input:            1 token1
attacker requested input:      1 raw token0 unit
attacker interval:             1 day
attack duration in PoC:        30 days
```

The price ratio represents an 18-decimal stablecoin/BTC-wrapper orientation at 50,000 stablecoin units per BTC-like token. The metric is per-share, so increasing the bin's TVL proportionally does not increase `H` or prevent the rounding condition.

The configuration is not an oracle-staleness or trusted-admin assumption:

- both oracle prices are correct and current;
- `58` is explicitly documented by the extension as approximately 5% decay per day and is used by the repository's own tests;
- 5% is a normal functional stop-loss drawdown;
- the attacker controls neither the pool admin nor the oracle;
- disabling drawdown or setting it to 100% would disable the extension's stop-loss purpose rather than mitigate the implementation bug.

## Proof of concept

Implemented at:

```text
metric-periphery/test/extensions/OracleValueStopLossDecayFreeze.audit.t.sol
```

Run:

```bash
cd metric-periphery
FOUNDRY_OFFLINE=true forge test \
  --match-path test/extensions/OracleValueStopLossDecayFreeze.audit.t.sol \
  -vvv
```

Observed output:

```text
[PASS] test_dailyDustSwapsFreezeDecayAndKeepDirectionBlocked()
watermark after three-day control decay: 17
initial token1 watermark: 19
live token1 metric after repricing: 16
watermark after thirty attacked days: 19
daily attacker calls: 30
total raw token0 paid by attacker: 0
cursor movement over attack: 0
```

The test also asserts that the victim direction reverts before the control, succeeds after three uninterrupted days, and still reverts after 30 attacker-maintained days.

## Impact

The attacker can override the pool admin's configured decay policy and maintain a one-way swap DoS for an arbitrary duration while the correct market price remains below the original floor. This prevents users and routers from executing the affected direction through the pool even though the extension was explicitly configured to adapt to a permanent repricing over time.

For the demonstrated pool, the blocked victim operation exchanges one BTC-like token against a bin containing approximately one million stablecoin units of initial liquidity. The issue therefore scales to economically meaningful pools; it is not limited to dust liquidity merely because the maintenance call itself is dust.

The attack can also disrupt multihop routes that require the blocked direction, because the entire route reverts when this hop's `afterSwap` check reverts.

This PoC does not rely on landing at a bin boundary. The cursor remains exactly unchanged across all 30 attacker calls. It is therefore distinct from the weaker boundary-bin false-positive lead.

## Preconditions and limits

- The pool must use `OracleValueStopLossExtension`.
- A bin must have a legitimate breached watermark for one direction while the opposite direction remains callable.
- The watermark, rate, and attacker interval must make each individual integer decrement zero.
- The oracle-priced metric must remain below the relevant floor. A favorable market move can clear the breach independently.
- The attacker must continue paying gas and refreshing the timestamp before a nonzero decrement accrues.
- Only one swap direction is blocked in the demonstrated state; liquidity withdrawal and the opposite direction are not shown to be blocked.
- The pool admin can recover through timelocked watermark/configuration changes. Pausing all swaps long enough for decay to accrue can also stop maintenance calls, but does so by making the whole pool unavailable during recovery.

## Recommendation

Do not discard fractional decay whenever the watermark timestamp is refreshed.

Preferred fixes include:

- store decay in higher precision and only round when comparing or persisting the displayed watermark;
- keep a per-watermark decay remainder and carry it into subsequent updates;
- retain the unconsumed portion of elapsed time instead of setting `lastDecayTs` fully to `block.timestamp` when an integer decay quantum has not accrued;
- use independent decay accounting for token0 and token1 watermarks rather than one shared timestamp.

As defense in depth, the pool should avoid invoking state-changing `afterSwap` behavior for swaps whose realized deltas and cursor movement are all zero. That alone is not a complete fix, because sufficiently small nonzero allowed-direction swaps may still reset the clock while losing fractional decay.
