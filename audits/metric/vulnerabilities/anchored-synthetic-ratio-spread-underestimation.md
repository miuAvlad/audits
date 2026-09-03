# Synthetic anchored providers underestimate ratio uncertainty when the quote leg has spread

## Severity

Potential Medium, pending final economic validation.

This is not a generic stale-price, Chainlink round-completeness, or trusted-parameter misconfiguration issue. The PoC uses an `AnchoredPriceProvider` created through `AnchoredProviderFactory` with in-envelope parameters. The issue is in the synthetic ratio math itself: when the provider builds a pair price from two feeds, denominator-side uncertainty is handled linearly even though ratio bounds are nonlinear.

The current PoC shows an approximately 8-9 bps underestimation in the ask for a valid `MAX_SPREAD_BPS = 300` configuration. This exceeds the contest's 0.01% Medium loss threshold if it can be exercised against meaningful pool liquidity. The remaining question is economic: whether a realistic pool and swap size can realize the underpriced quote into loss above the threshold.

## Summary

`AnchoredPriceProvider` supports synthetic pairs by reading two independent oracle feeds and computing:

```solidity
mid = mid1 / mid2;
spreadBps += spreadBps2;
```

The combined `spreadBps` is then used as a linear half-width around the synthetic midpoint:

```solidity
half = spreadBps * ONE_BPS_E18 + minMargin;
ask = mid * (1 + half);
bid = mid * (1 - half);
```

This is a good first-order approximation for small spreads, but it is not a conservative bound for a ratio when the denominator feed has non-zero uncertainty.

For a ratio `A / B`, the conservative bounds are:

```text
lower = A_mid * (1 - spreadA) / (B_mid * (1 + spreadB))
upper = A_mid * (1 + spreadA) / (B_mid * (1 - spreadB))
```

The denominator must be divided by `1 - spreadB` for the upper bound. Adding `spreadB` linearly underestimates the upper bound by roughly `spreadB^2 / (1 - spreadB)`.

## Affected code

- `smart-contracts-poc/contracts/AnchoredPriceProvider.sol`
  - `_getBidAndAskPrice()`
  - `_computeBidAsk()`

Synthetic mode computes the ratio and adds bps spreads:

```solidity
mid = Math.mulDiv(mid, ORACLE_DECIMALS, mid2);
spreadBps += spreadBps2;
```

Then `_computeBidAsk()` applies the summed spread linearly:

```solidity
uint256 half = spreadBps * ONE_BPS_E18 + minMargin;
uint256 refAsk = _bandEdge(mid, BPS_BASE_U + half, Math.Rounding.Ceil);
```

## Root cause

The implementation treats relative uncertainty of a division as simple addition on both sides of the final midpoint. That is only a linear approximation.

For the ask side of `baseFeed / quoteFeed`, the worst case is:

```text
baseFeed high / quoteFeed low
```

So the denominator spread increases the ratio through division:

```text
1 / (1 - quoteSpread)
```

The contract instead uses:

```text
1 + quoteSpread
```

For `quoteSpread = 300 bps`, the contract uses about `1.0300`, while the denominator-side exact factor is about `1.0309278`. With the configured `0.5 bps` floor, the PoC still shows the final ask is about 8 bps too tight.

## Impact

For synthetic providers, the final bid/ask band can be tighter than the actual oracle uncertainty interval. This violates the intended anchored-provider safety model that the band is the load-bearing bound around how wrong the quote can be.

If a pool prices swaps from a synthetic provider affected by this issue, traders can buy the base asset too cheaply whenever the denominator feed has meaningful spread. LPs on the other side of the trade receive less than the conservative oracle-bound quote should require.

The impact scales with:

- the denominator feed spread;
- the pool's available liquidity at the affected price;
- the configured `MAX_SPREAD_BPS`;
- whether the pool uses synthetic `quoteFeedId != bytes32(0)` providers.

This is not caused by a malicious provider owner selecting bad parameters. In the PoC, the provider is created through the official factory with valid envelope bounds.

## Concrete example

Assume a synthetic BTC/ETH provider built from:

```text
BTC/USD = 65000, spread = 0 bps
ETH/USD = 3000, spread = 300 bps
minMargin = 0.5 bps
MAX_SPREAD_BPS = 300
```

The current contract computes the synthetic midpoint:

```text
BTC/ETH = 65000 / 3000 = 21.666...
```

Then it applies the linear summed spread:

```text
ask ~= mid * (1 + 300.5 bps)
```

The conservative upper bound should account for ETH/USD being lower by 300 bps:

```text
ask ~= mid * (1 / 0.97 + 0.5 bps)
```

The contract ask is therefore about 8-9 bps lower than the exact ratio bound.

## PoC

A Foundry PoC was added at:

```text
smart-contracts-poc/test/AnchoredSyntheticRatioSpreadPoC.t.sol
```

The PoC:

1. Deploys `AnchoredProviderFactory`.
2. Sets a valid envelope with `maxSpreadMax = 300`.
3. Creates an `AnchoredPriceProvider` through the factory with `quoteFeedId != 0`.
4. Sets `baseSpreadBps = 0` and `quoteSpreadBps = 300`.
5. Reads the provider ask.
6. Recomputes both the contract's linear ask and the exact ratio upper bound.
7. Proves the provider ask equals the linear result and is lower than the exact bound by more than 7 bps.

Run:

```bash
cd smart-contracts-poc
forge test --match-path test/AnchoredSyntheticRatioSpreadPoC.t.sol -vvv
```

Observed result:

```text
[PASS] test_syntheticRatioAskIsTighterThanExactDenominatorUncertainty()
```

## Why this is stronger than the discarded confidenceParam angle

The earlier `confidenceParam` idea can be dismissed as trusted provider-parameter tuning, because the README explicitly accepts that mis-tuned oracle/provider guards can cause bad-price execution.

This issue is different. The parameters are within the factory envelope, and the provider is using the standard anchored path. The underestimation comes from the ratio math, not from a trusted party choosing an obviously unsafe value.

## Validity notes

This finding still needs a final impact check before submission.

Reasons it may pass:

- The README treats anchored band math as the safety boundary.
- The issue occurs with valid factory-created parameters.
- The PoC demonstrates a price error larger than 0.01%.
- A swap priced from this ask can undercharge buyers of the base asset in a synthetic pair.

Reasons it may be challenged:

- The PoC proves quote underestimation, not yet full pool-level realized loss.
- The underestimation is bounded by `MAX_SPREAD_BPS`; for very low spread configurations, impact may be small.
- Pools must actually use synthetic `quoteFeedId` providers.

## Recommendation

Do not combine ratio feed uncertainties by simply adding bps and applying them linearly to the final midpoint.

Compute ratio bounds directly:

```text
bid = (baseMid * (1 - baseSpread)) / (quoteMid * (1 + quoteSpread))
ask = (baseMid * (1 + baseSpread)) / (quoteMid * (1 - quoteSpread))
```

Then apply `minMargin` conservatively to the resulting bid/ask, or convert those exact bounds back into a final synthetic spread that is rounded outward.

Also ensure `MAX_SPREAD_BPS` is checked against the exact combined ratio uncertainty, not only against `spreadA + spreadB`.



**Core Bug**

The vulnerable path is synthetic pricing in [AnchoredPriceProvider.sol](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/smart-contracts-poc/contracts/AnchoredPriceProvider.sol:257).

When `quoteFeedId != 0`, the provider builds a synthetic pair price:

```solidity
mid = Math.mulDiv(mid, ORACLE_DECIMALS, mid2);
spreadBps += spreadBps2;
```

So for `BTC/ETH`, it does:

```text
BTC/ETH = BTC/USD / ETH/USD
```

Then it adds both feeds’ uncertainty/spread and applies that linearly around the synthetic midpoint:

```text
ask = syntheticMid * (1 + spreadA + spreadB + floor)
bid = syntheticMid * (1 - spreadA - spreadB - floor)
```

The problem is: **division does not preserve uncertainty linearly**.

**Correct Math**

Assume:

```text
A = base feed, e.g. BTC/USD
B = quote feed, e.g. ETH/USD

synthetic price = A / B
```

If each feed has uncertainty:

```text
A is really between A_mid * (1 - spreadA) and A_mid * (1 + spreadA)
B is really between B_mid * (1 - spreadB) and B_mid * (1 + spreadB)
```

Then the conservative synthetic bounds are:

```text
lowest A/B  = A_low  / B_high
highest A/B = A_high / B_low
```

So:

```text
bid should be:
A_mid * (1 - spreadA) / (B_mid * (1 + spreadB))

ask should be:
A_mid * (1 + spreadA) / (B_mid * (1 - spreadB))
```

The dangerous part is the ask:

```text
correct denominator factor = 1 / (1 - spreadB)
```

But the contract approximates it as:

```text
1 + spreadB
```

Those are not equal.

Example with `quoteSpread = 300 bps = 3%`:

```text
contract factor: 1 + 0.03 = 1.03

correct factor: 1 / (1 - 0.03) = 1 / 0.97 = 1.030927835
```

So the contract ask is too low by about:

```text
1.030927835 - 1.03 = 0.000927835
≈ 9.27 bps
```

That means the pool can sell the base asset too cheaply.

**Concrete Example**

Synthetic provider:

```text
BTC/USD = 65,000
ETH/USD = 3,000
BTC spread = 0 bps
ETH spread = 300 bps
```

Synthetic midpoint:

```text
BTC/ETH = 65,000 / 3,000 = 21.666666 ETH per BTC
```

Contract ask:

```text
21.666666 * 1.03 = 22.316666 ETH per BTC
```

Correct conservative ask:

```text
21.666666 / 0.97 = 22.336769 ETH per BTC
```

Difference:

```text
22.336769 - 22.316666 = 0.020103 ETH per BTC
≈ 9 bps
```

So a trader buying BTC from the pool pays around 9 bps less than the conservative oracle band says they should. If the pool has enough liquidity, that can become LP loss.

**Why This Is A Real Finding Angle**

The README says the anchored band is the safety boundary: [README.md](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/README.md:48). It also says band math errors can be valid high-impact cases: [README.md](/workspaces/web3-dev-containers/foundry/second_setup/audits/solidity-audits/2026-07-metric-miuAvlad/README.md:60).

So the issue is not stale price, downtime, or malicious provider configuration. The issue is:

```text
The documented safety band is computed with a non-conservative formula for synthetic ratio providers.
```

The existing tests prove the additive formula is intentional behavior, but that does not kill the finding. It means the bug is a **design/math bug**, not an accidental implementation mismatch.

Best framing:

> Synthetic providers use `spreadA + spreadB` as a linear approximation, but ratio uncertainty requires dividing by the denominator’s lower bound. As a result, the ask can be below the true conservative upper bound, allowing swaps against LPs at an underpriced oracle quote.