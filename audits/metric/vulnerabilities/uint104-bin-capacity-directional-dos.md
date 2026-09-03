# High-decimal tokens let an attacker saturate a bin and block an entire swap direction

## Severity

**Medium**

The issue causes a persistent, permissionless denial of one swap direction for a pool. It requires a token pair whose internal precision makes the `uint104` per-bin limit economically reachable, but it does not require a malicious pool admin, a bad oracle, or a non-standard token implementation. LP withdrawals and swaps in the opposite direction remain available, so High severity is not justified.

## Summary

Metric normalizes both pool assets to the larger token precision, but stores each bin balance in a `uint104`. With an 18-decimal token paired against a standard 30-decimal ERC-20, one external token0 wei represents `1e12` internal units and a bin can hold only:

```text
type(uint104).max / 1e30 = approximately 20.2824 whole tokens
```

`buyToken1InBinSpecifiedIn()` does not limit accepted input to the bin's remaining `uint104` capacity. An attacker can therefore leave the current bin with:

```text
0 < type(uint104).max - token0BalanceScaled < TOKEN_0_SCALE_MULTIPLIER
```

At that point even the smallest nonzero external token0 input exceeds the remaining internal capacity. Every token0-to-token1 swap reverts at the `toUint104()` cast, even though the current bin still contains token1 and lower bins contain substantial token1 liquidity. The outer loop cannot partially fill the swap or skip the blocking bin.

The PoC creates this state from an ordinary initial cursor and narrow `lengthE6 = 100` bins using two permissionless swaps. At a constant 1:1 oracle price, the two legs cost the attacker only approximately `6.34e-9` token units while blocking approximately `20.28` token1 units in the next bin.

## Root Cause

The factory chooses the larger token precision as the common internal precision and does not cap supported decimals:

```solidity
uint8 internalDecimals = 18;
if (token0Decimals > internalDecimals) internalDecimals = token0Decimals;
if (token1Decimals > internalDecimals) internalDecimals = token1Decimals;
token0ScaleMultiplier = 10 ** (internalDecimals - token0Decimals);
token1ScaleMultiplier = 10 ** (internalDecimals - token1Decimals);
```

For an 18/30-decimal pair:

```text
TOKEN_0_SCALE_MULTIPLIER = 1e12
TOKEN_1_SCALE_MULTIPLIER = 1
```

However, every bin balance remains only `uint104`. The exact-input token0-to-token1 path unconditionally adds the chosen input after calculating output and cursor movement:

```solidity
binState.token1BalanceScaled -= out1Scaled.toUint104();
binState.token0BalanceScaled =
  (uint256(binState.token0BalanceScaled) + totalIn0Scaled - protocolFeeAmountScaled).toUint104();
```

There is no capacity-aware partial fill before this cast.

The pool loop invokes this function while the current bin has token1 and `curPosInBin > 0`. Since the cast reverts, execution never reaches the logic that could move to another bin:

```solidity
while (state.amountSpecifiedRemainingScaled > 0) {
  // current nonempty bin is processed first
  SwapMath.buyToken1InBinSpecifiedIn(...);

  if (curPosInBinCache == 0 || !nonEmptyBin) {
    curBinIdxCache--;
    // ...
  }
}
```

The same missing capacity handling exists symmetrically when token1 enters a bin and in the exact-output paths.

## Attack Flow

1. A permissionless pool contains a standard 18-decimal token0 and standard 30-decimal token1. Both are normalized to 30 internal decimals.
2. LPs supply approximately `20.28` token0 to current bin `0` and approximately `20.28` token1 to lower bin `-1`.
3. The attacker swaps token1 for token0, moving the cursor into bin `0` and receiving token0.
4. The attacker swaps that token0 back in the opposite direction, selecting the largest whole external token0 amount that fits in the remaining scaled capacity.
5. Bin `0` ends with token0 headroom smaller than `1e12` scaled units, while it still has token1 and a nonzero cursor position.
6. One token0 wei necessarily scales to `1e12`, so every subsequent token0-to-token1 swap overflows the `uint104` balance and reverts.
7. The revert occurs before the loop can reach bin `-1`, making all token1 liquidity below the blocking bin inaccessible.
8. The state persists without continued attacker transactions. An opposite swap can temporarily create headroom, and LP removal can clear the bin, but ordinary swaps in the blocked direction cannot progress through it.

The pool transfers output before invoking the swap callback, so the attack's inventory exchange can also be composed with external liquidity; it does not require donating the blocked notional to the pool.

## Impact

- Every swap in one direction reverts regardless of how small its external input is.
- A dust amount left in the saturated current bin blocks all liquidity in every downstream bin.
- Oracle updates do not release the lock because the failure is balance-capacity based.
- The attacker does not need to remain active after creating the state.
- The condition can affect either direction because all four in-bin swap paths cast incoming balances to `uint104` without capacity-aware execution.

This is not merely a user asking for an oversized swap. The attacker changes shared pool state so that **no representable nonzero external input from any later user fits**.

## Proof of Concept

The end-to-end test deploys the 18/30-decimal pool through the production `MetricOmmPoolFactory.createPool()` path and is located at:

```text
metric-core/test/MetricOmmPool.uint104Capacity.audit.t.sol
```

Run it with:

```bash
forge test --match-path test/MetricOmmPool.uint104Capacity.audit.t.sol -vv
```

Observed values:

```text
initial token0 raw amount         20.282409603651670422
residual scaled token0 capacity  326467327428
minimum scaled token0 input      1000000000000
token1 remaining in current bin  6337460803527377005466
token1 blocked in lower bin      20282409603651670422000000000000
attacker cost at oracle mid      6337460805527377005466
```

The test then proves that a one-wei token0 swap reverts, performs an opposite dust swap to create headroom, and confirms that the same one-wei swap succeeds only after that headroom exists.

## Why The Token Is In Scope

The contest README permits any standard ERC-20 and states that there is no token whitelist. A vanilla ERC-20 returning `30` from `decimals()` does not have fee-on-transfer, rebasing, callbacks, or any other non-standard behavior. The factory explicitly reads arbitrary token decimals and normalizes to their maximum, and neither the code nor the pool-configuration documentation states an upper supported decimal limit.

## Recommendation

Use a balance representation wide enough for the maximum supported internal precision and realistic pool sizes. In addition:

1. Define and enforce a maximum supported token precision at pool creation.
2. Validate that the resulting external per-bin capacity is above a documented minimum for both assets.
3. Make swap execution capacity-aware so an oversized request cannot revert when a valid partial fill exists.
4. Add invariant tests asserting that a nonempty current bin cannot become impassable merely because its incoming balance is close to the storage maximum.

Capacity-aware partial fills improve oversized-swap behavior, but they do not fully solve the state where less than one external unit fits. A wider balance type or a strict decimals/capacity bound is still required.
