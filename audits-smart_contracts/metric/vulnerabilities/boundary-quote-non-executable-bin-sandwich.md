# Boundary quotes use a non-executable bin and can weaken slippage protection enough to enable profitable sandwiches

## Severity

Medium candidate.

The PoC demonstrates a permissionless sandwich that causes a victim to lose 16.1959 token1, or 0.6478% of the output they would receive without the attack, while the attacker earns 15.1166 token1. Assuming token1 is worth $1, both the victim loss and attacker profit exceed $10.

The main submission risk is that the protocol also supplies `MetricOmmSwapQuoter`, which simulates the complete swap and returns the correct amount for a specified trade size. The demonstrated loss applies when an integration uses the official `getSellAndBuyPrices()` marginal-price API to derive slippage protection. This is plausible for small trades, but judges may expect integrations to use the exact simulation quoter instead.

## Summary

`MetricOmmPool.getSellAndBuyPrices()` calculates both directional quotes from the bin stored in `curBinIdx`:

```solidity
BinState memory binState = _binStates[curBinIdx];

uint256 marginalPriceX64 =
  SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, curPosInBin, Math.Rounding.Floor);

uint256 buyFeeX64 = baseFeeX64 + Math.mulDiv(binState.addFeeBuyE6, ONE_X64, 1e6);
uint256 sellFeeX64 = baseFeeX64 + Math.mulDiv(binState.addFeeSellE6, ONE_X64, 1e6);
```

At a bin boundary, however, the stored bin is not necessarily executable in both directions:

- At `curPosInBin == 0`, a `token0 -> token1` sell cannot use the current bin and moves to a lower bin.
- At `curPosInBin == type(uint104).max`, a `token1 -> token0` buy cannot use the current bin and moves to a higher bin.
- If the adjacent bin has no relevant liquidity, traversal continues through additional empty bins.

The real swap therefore uses the marginal price and directional fee of the first executable bin, while `getSellAndBuyPrices()` always uses the stored cursor bin. The official `MetricOmmPoolDataProvider` duplicates the same behavior in `_marginalBestBidAsk()`.

When the stored bin has a higher directional fee than the executable adjacent bin, the reported price is pessimistic. An integration that converts this official marginal price into `amountOutMinimum` unintentionally grants more slippage than requested. An attacker can consume that false tolerance with a conventional front-run and back-run sandwich.

## Affected code

### Core quote

`metric-core/contracts/MetricOmmPool.sol:523-548`

`getSellAndBuyPrices()` reads only `_binStates[curBinIdx]` and applies that bin's buy and sell fees without resolving whether the bin can execute each direction.

### Real sell traversal

`metric-core/contracts/MetricOmmPool.sol:1070-1113`

For a `token0 -> token1` sell, the pool marks the current bin non-executable when `curPosInBinCache == 0`, decrements `curBinIdxCache`, loads the lower bin, and later applies that lower bin's `addFeeSellE6`:

```solidity
if (binState.token1BalanceScaled == 0 || curPosInBinCache == 0) {
  nonEmptyBin = false;
}

if (curPosInBinCache == 0 || !nonEmptyBin) {
  curBinIdxCache--;
  binState = _binStates[curBinIdxCache];
  curPosInBinCache = type(uint104).max;
}
```

The symmetric problem exists for buys at the upper boundary.

### Official data-provider quote

`metric-periphery/contracts/lens/MetricOmmPoolDataProvider.sol:267-302`

`_marginalBestBidAsk()` also loads fee and length data only from `curBinIdx`, so `referenceBestBidX64` and `referenceBestAskX64` can report a non-executable level.

## Root cause

The cursor identifies one representation of the current price boundary, not one bin that is necessarily executable in both directions.

The equivalent boundary price may be represented as either:

```text
(bin i, position 0)
(bin i - 1, position MAX)
```

At that price:

- the executable sell side belongs to bin `i - 1`;
- the executable buy side belongs to bin `i`.

`getSellAndBuyPrices()` assumes a single `curBinIdx` can provide both sides. This is incorrect whenever the cursor is at an edge, and it becomes more inaccurate when adjacent bins are empty or have different directional fees.

The interface explicitly describes these values as:

> the prices a zero-size exact-in swap would execute at

At a boundary, an infinitesimal real swap first traverses to the directional executable bin, so the reported quote does not satisfy that documented behavior.

## Attack path

The PoC uses a pool with:

```text
cursor:                       bin 0, position 0
bin 0 addFeeSellE6:           20,000 = 2%
bin -1 addFeeSellE6:          0
bin -1 token1 liquidity:      1,000,000 token1
victim exact input:           2,500 token0
victim requested slippage:    0.5%
attacker front-run input:     100,000 token0
```

This does not require a malicious pool admin. Per-bin fees are valid bounded configuration, and a 2% difference between adjacent bins is enough for the demonstrated loss. The boundary state can occur naturally or be reached through public swaps.

The attack proceeds as follows:

1. The pool cursor is `(bin 0, position 0)`.
2. The victim or its integration calls `getSellAndBuyPrices()`.
3. The function applies bin 0's 2% sell fee even though bin 0 cannot execute a sell from position zero.
4. The integration applies its intended 0.5% tolerance to this already pessimistic price and obtains `amountOutMinimum = 2,438.7255`.
5. The correct executable-bin quote would produce `amountOutMinimum = 2,487.2979`.
6. The attacker sees the pending swap and sells 100,000 token0 first, moving the active position down inside bin -1.
7. The victim's swap executes and receives 2,483.6010 token1.
8. This passes the minimum derived from the wrong quote but would revert against the correct executable-bin minimum.
9. The attacker buys back the 100,000 token0 at the post-victim position and retains 15.1166 token1 profit.

## Impact

The measured outcomes are:

```text
minimum from wrong boundary quote:  2,438.725490196078431240
minimum from executable quote:      2,487.297890626241700724
victim output without sandwich:     2,499.796875001247940555
victim output after sandwich:       2,483.601002993444692257
victim loss:                           16.195872007803248298
victim loss percentage:                 0.6478%
attacker token1 profit:                15.116618428518795715
```

At a $1 token1 valuation, the victim loses more than $10 and more than 0.01%, satisfying the contest's quantitative Medium threshold. The attack scales with trade and pool size.

The victim trade is only 0.25% of the demonstrated pool's token1 depth. Its unsandwiched execution differs only slightly from the true marginal price, so the result does not rely on using a zero-size quote for a trade with large self-induced price impact.

The same root cause can produce a much larger read discrepancy when empty bins are present. A separate PoC places liquidity fourteen empty bins away and observes a 91% difference between the reported marginal sell price and the first executable price. That case strengthens the root-cause proof, although an optimistic quote across empty bins generally causes reversion rather than the sandwich loss demonstrated above.

## Proof of concept

Implemented in:

```text
metric-core/test/MetricOmmPool.binBoundaryOscillation.audit.t.sol
```

The primary impact test is:

```text
test_pessimisticBoundaryQuoteCanCreateSandwichTolerance()
```

Additional root-cause tests are:

```text
test_boundaryQuoteUsesStoredBinFeeInsteadOfTradableAdjacentBinFee()
test_boundaryQuoteDoesNotWalkAcrossEmptyBinsToExecutableLiquidity()
test_repeatedFullBoundaryOscillationDoesNotCreateTraderValue()
```

Run:

```bash
cd metric-core
FOUNDRY_OFFLINE=true forge test \
  --match-path test/MetricOmmPool.binBoundaryOscillation.audit.t.sol \
  -vv
```

Observed result:

```text
4 passed; 0 failed
```

## Why the full swap quoter does not remove the root cause

`MetricOmmSwapQuoter.quoteLiveExactInSingle()` invokes the actual pool swap in a reverting simulation. It therefore traverses bins correctly and returns the correct amount for the requested trade size.

Using that quoter prevents the demonstrated slippage calculation error. It does not make `getSellAndBuyPrices()` or `MetricOmmPoolDataProvider.referenceBestBidX64/referenceBestAskX64` correct. These remain official integration-facing price APIs whose documented marginal values can refer to a non-executable bin.

This distinction is also the finding's principal validity risk: a judge may conclude that integrations requiring executable amount quotes must always use `MetricOmmSwapQuoter`. The counterargument is that the affected API expressly promises executable zero-size prices and is a natural input for slippage calculations on small trades.

## Recommendation

Resolve the marginal executable bin separately for each direction.

For the sell quote:

1. If `curPosInBin > 0` and the current bin has executable token1 liquidity, use the current bin.
2. Otherwise walk downward until finding a bin with executable token1 liquidity.
3. Use that bin's upper boundary price, `addFeeSellE6`, and the shared oracle/notional fees.

For the buy quote:

1. If `curPosInBin < type(uint104).max` and the current bin has executable token0 liquidity, use the current bin.
2. Otherwise walk upward until finding a bin with executable token0 liquidity.
3. Use that bin's lower boundary price, `addFeeBuyE6`, and the shared oracle/notional fees.

Apply the same directional traversal in `MetricOmmPoolDataProvider._marginalBestBidAsk()`.

If no executable liquidity exists in a direction, return an explicit no-liquidity indication or revert rather than reporting the fee and price of a bin that cannot execute.
