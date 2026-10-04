# Eight-decimal oracle normalization can make the pool trade below a fresh signed price

## Severity

**Medium**

The end-to-end PoC uses a fresh, correctly signed Pyth observation for a low-priced
asset, a real `PythOracle`, a factory-created `AnchoredPriceProvider`, ordinary
provider bounds, a real pool with 18-decimal SHIB and 6-decimal USDC, and a nonzero
`5 bps` notional fee. The attacker remains profitable after all fees, while the LP
position loses more than one basis point and more than `$10` of principal value.

The attack requires a supported low-priced feed to be sufficiently close to an
eight-decimal quantization boundary and enough pool liquidity to monetize the
mispricing. These conditions make Medium more defensible than High.

Selecting a larger `minMargin` at provider deployment is not a general
configuration-level defense. `minMargin` is immutable, while the relative error of
discarding one eight-decimal unit increases as the authenticated price decreases.
Because no minimum supported feed price or bounded future price range is documented,
a margin that is conservative at deployment can become insufficient after an
ordinary price movement. Covering the lowest representable prices would require a
permanent margin approaching 100%, which the provider rejects and which would in any
case make ordinary execution economically unusable.

## Summary

`LazerConsumer` floors every Pyth observation to eight decimals before storing it:

```solidity
if (totalExpo >= 0) {
    rawPrice = pU * (10 ** totalExpo.toUint256());
} else {
    rawPrice = pU / (10 ** (-totalExpo).toUint256());
}

normPrice = rawPrice.toUint64();
spreadU = Math.ceilDiv(BPS_BASE * uint256(conf), pU);
```

The confidence spread is calculated from the original full-precision `pU`, but it
does not include the value discarded by the division. `AnchoredPriceProvider` then
constructs the executable band around the already-floored midpoint.

Consequently, a correct and fresh source price can remain above the final pool ask
after the configured confidence spread, minimum margin, and ordinary swap fees. An
arbitrageur can buy the underpriced inventory and realize the difference externally,
transferring LP principal value to the attacker and fee recipients.

Although the attacker realizes the loss through an arbitrage transaction, this is
not ordinary arbitrage caused by market movement or a delayed oracle update.
Holding the signed observation, provider configuration, pool fee, and liquidity
constant, constructing the quote from the full-precision source midpoint places the
fee-inclusive ask above the source midpoint and makes the trade unprofitable.
Replacing only that midpoint with the protocol's floored eight-decimal value moves
the fee-inclusive ask below the same signed midpoint and creates the profitable
crossed quote. The normalization floor is therefore the necessary cause of the
opportunity; external execution merely realizes the LP principal loss created
inside the pool.

`ChainlinkOracle._toMid8` contains the same direct-ingestion floor when converting
18-decimal Data Streams prices to the shared eight-decimal format. The PoC uses Pyth
because it proves the full signed-payload path, but the root is shared.

## Root Cause

Let `P` be the authenticated full-precision price and `q = 1e-8` the protocol's
price unit. The stored price is:

```text
P8              = floor(P / q) * q
normalizationGap = P - P8
```

For Pyth, the source confidence is converted independently:

```text
u = ceil(confidence / P)
```

The immutable Anchored provider then approximately returns:

```text
ask = P8 * (1 + u + minimumMargin)
```

Buying from the pool remains underpriced whenever:

```text
normalizationGap / P > u + minimumMargin + notionalFee + binPriceImpact
```

The relative quantization error grows as the asset price decreases. A fixed provider
margin can therefore be sufficient when a provider is deployed and become
insufficient after an ordinary market decline, without any configuration change.

For the PoC's fresh `$0.0000050099` Pyth observation:

```text
signed source price:       0.0000050099
stored eight-decimal mid:  0.0000050000
source confidence:         1.0 bps
minimum margin:            0.5 bps
final anchored ask:        0.000005000750
ask underpricing:          approximately 18.26 bps
```

### Why immutable `minMargin` cannot cover the unrestricted price domain

`AnchoredPriceProvider.minMargin` is fixed in the constructor and has no update
path. The factory checks it against the selected feed-class envelope only when the
provider is created. It is therefore impossible to increase the protection of an
existing provider when the asset later trades at a price with worse relative
eight-decimal precision.

For a floored midpoint `P8`, the additional margin needed to cover normalization
alone is:

```text
roundingMarginRequired = (P - P8) / P8
```

Within the eight-decimal bucket `[n * 1e-8, (n + 1) * 1e-8)`, the worst-case
required margin approaches:

```text
1 / n
```

This requirement is price-dependent:

```text
authenticated price     stored P8          rounding margin required
0.0000123499             0.0000123400       approximately 8.02 bps
0.0000050099             0.0000050000       approximately 19.80 bps
0.0000000199             0.0000000100       approximately 99%
```

The provider requires `maxSpreadBps + minMargin < 100%`, so no permitted immutable
margin can conservatively cover every nonzero price representable by the shared
eight-decimal format. A very large margin is also not a neutral workaround: it
permanently widens every bid and ask even when normalization error is small, worsens
execution, compounds across multihop routes, and can make the pool economically
unusable.

Consequently, responsibility cannot safely be shifted to the pool creator unless
the protocol defines and enforces a minimum price or a bounded supported price range
for every feed. Neither restriction is documented. The conversion must instead
carry the discarded remainder into `spread0` or preserve sufficient source
precision.

This is distinct from `anchored-synthetic-ratio-precision-loss.md`. That finding
loses precision while dividing two already-normalized feeds inside
`AnchoredPriceProvider`; this finding loses precision while ingesting one direct,
authenticated oracle observation before the provider receives it.

## Attack

1. A normal SHIB/USDC pool uses a direct Pyth feed through an immutable
   `AnchoredPriceProvider`.
2. Pyth publishes a fresh, correctly signed low-priced observation whose exponent
   provides more than eight decimal places.
3. `LazerConsumer._normalize` floors the observation to eight decimals but does not
   add the discarded remainder to `spread0`.
4. The provider constructs its bid and ask around the floored midpoint. Staleness,
   price guard, and spread checks all pass because the observation is valid.
5. The attacker exact-output buys inventory from the affected side of the pool.
6. The attacker sells or hedges that inventory at the full oracle-implied market
   value. The configured `5 bps` notional fee reduces but does not eliminate profit.

No malicious oracle, stale observation, trusted-role action, price update during the
swap, custom extension, or unusual token behavior is required.

## Economic Impact

The real-pool PoC seeds one bin with one trillion SHIB, worth approximately
`$5.0099 million`, and purchases only 10% of the inventory. The remaining 90%
proves that the result does not rely on draining the bin or on an empty-bin
transition.

```text
signed Pyth SHIB price:             0.000005009900000000
stored eight-decimal midpoint:      0.000005000000000000
anchored ask:                       0.000005000750000000
ask underpricing before fee:        approximately 18.26 bps
SHIB bought:                        100,000,000,000
true USDC value bought:             500,990.000000 USDC
USDC paid including 5 bps fee:      500,327.501623 USDC
attacker profit:                    662.498377 USDC
attacker gross edge:                13.2412 bps
LP principal loss:                 912.499624... USDC
LP principal loss:                 1.8213 bps (0.018213%)
```

The LP loss exceeds attacker profit because the separate notional fee is retained
outside the bins for protocol collection. That fee does not restore the LP's lost
inventory value.

The attack is executed as an arbitrage, but the measured profit should not be
classified as an ordinary market-dislocation gain. No external price movement is
needed between oracle ingestion and execution. In the controlled counterfactual
where the exact same observation is kept at full precision, the configured
confidence, margin, and notional fee make the trade loss-making. Flooring alone
reverses that result and causes the pool to transfer inventory below its
authenticated value.

The pool leg can be financed with a flash loan only if the external sale or hedge is
also completed atomically. This scenario requires approximately `500,327.50 USDC`
of temporary principal and leaves a measured gross edge of `13.2412 bps`; therefore,
the combined flash-loan fee, external-market slippage, and gas must remain below
that edge. The PoC deliberately does not mock a lender or an external venue, so it
proves the pool-side underpricing and oracle-valued profit, rather than claiming
that a particular venue offers sufficient same-block liquidity. Flash financing is
possible under that cost bound, but it is not required: the same permissionless
loss is realizable with attacker-owned or otherwise borrowed capital.

## Why Oracle and Extension Guards Do Not Prevent It

- The source observation is fresh, signed, correct, and monotonically newer.
- `priceGuard` receives only the floored eight-decimal midpoint.
- `AnchoredPriceProvider` assumes its input midpoint already represents the source
  price and only expands it by the reported confidence and configured margin.
- PriceVelocity and stop-loss extensions consume the same provider bid/ask and
  cannot recover the discarded digits.
- Router slippage protects the attacker performing the swap, not passive LP
  inventory quoted at an incorrect oracle-derived edge.
- Multihop routing can atomically monetize the discrepancy, but it is not required
  for the loss.

The contest assumption that oracle observations are correct and not stale therefore
does not invalidate this issue: the harmful conversion occurs in protocol code after
the valid observation is received.

## Tests

- `smart-contracts-poc/test/PythDirectPricePrecision.audit.t.sol` submits a signed
  Lazer payload through the real proxy and signer verification, stores it in the real
  `PythOracle`, creates an eligible provider through the real provider factory, and
  proves that the final ask remains below the signed price.
- `metric-periphery/test/PythDirectPricePrecisionPool.audit.t.sol` carries the stored
  midpoint through a real pool swap, token scaling, bin accounting, and nonzero
  notional fee, then measures attacker profit and LP principal loss at the signed
  source price.

```bash
cd smart-contracts-poc
FOUNDRY_OFFLINE=true forge test \
  --match-path test/PythDirectPricePrecision.audit.t.sol -vv

cd ../metric-periphery
FOUNDRY_OFFLINE=true forge test \
  --match-path test/PythDirectPricePrecisionPool.audit.t.sol -vv
```

## Recommendation

### Preferred fix: preserve source precision

Do not irreversibly normalize authenticated prices to eight decimals before
constructing the executable band. Store the source mantissa and exponent, or use a
higher-precision common representation, and convert the full-precision bid and ask
directly to Q64.64 with pool-favoring outward rounding:

```text
q64Bid = floor(fullPrecisionBid * 2^64)
q64Ask = ceil(fullPrecisionAsk * 2^64)
```

The provider margin can then be applied to these full-precision bounds. This avoids
making safety dependent on the absolute price of the asset or on a pool creator
predicting its future price range.

### ABI-compatible fix: add the remainder to uncertainty

If `OracleData.price` must remain an eight-decimal `uint64`, keep flooring the stored
midpoint but calculate `spread0` relative to that floored midpoint and include both
the source uncertainty and the complete discarded remainder. The resulting upper
edge must satisfy:

```text
storedMid * (1 + spread0 / BPS_BASE) >= authenticatedUpperBound
```

For a Pyth value whose normalization divides its mantissa by `divisor`, the minimal
compatible calculation is:

```solidity
uint256 mid8 = pU / divisor;
require(mid8 != 0, InvalidReportPrice());

uint256 representedMantissa = mid8 * divisor;
uint256 upperMantissa = pU + uint256(conf);

uint256 spreadU = Math.ceilDiv(
    BPS_BASE * (upperMantissa - representedMantissa),
    representedMantissa
);
```

When normalization instead multiplies the mantissa, there is no discarded
remainder, so the existing confidence conversion can be retained. Any result at or
above the protocol's stalled-spread marker should fail closed.

For Chainlink Data Streams, calculate the stored midpoint first and derive the
combined spread from the full-precision upper bound:

```solidity
uint256 sourceMid = uint256(int256(price));
uint256 mid8 = sourceMid / PRICE_SCALE;
require(mid8 != 0, InvalidReportPrice());

uint256 representedMid = mid8 * PRICE_SCALE;
uint256 halfWidth = uint256(int256(ask) - int256(bid)) / 2;
uint256 authenticatedUpperBound = sourceMid + halfWidth;

uint256 spreadU = Math.ceilDiv(
    uint256(BPS_BASE) * (authenticatedUpperBound - representedMid),
    representedMid
);
```

For open V4 reports that do not contain bid and ask values, use `sourceMid` as the
upper bound. This produces a nonzero spread whenever `_toMid8()` discarded a
remainder. Calculating the complete bound in one expression is preferable to simply
adding independently rounded confidence and remainder spreads, because the latter
can still miss cross-term precision.

This symmetric-spread compatibility fix may make the bid more conservative than
necessary. A representation containing independent lower and upper bounds would
avoid that widening while preserving both sides exactly.

Add regression and invariant tests proving that, for every accepted source value:

```text
providerBid <= authenticatedLowerBound
providerAsk >= authenticatedUpperBound
```

Exercise values immediately below and above every eight-decimal boundary, both
direct oracle backends, zero-spread V4 reports, nonzero confidence/bid-ask reports,
and prices approaching the lowest representable positive value. If those properties
cannot be maintained for a feed, reject it explicitly and document the corresponding
minimum supported price.
