# [I] PriceProvider applies oracle confidence multipliers 100x below their documented scale, enabling cross-pool arbitrage

## Summary
Documentation issue.
The oracle layer reports `spread` in whole basis points, where `500` means 500 bps (5%). The `PriceProvider` family documents `confidenceParam = 10_000` as a 1x multiplier and `1_000_000` as 100x, but divides `spread * confidenceParam` by `1e10` when constructing bid and ask prices.

For whole-bps input and a 10,000-based multiplier, the correct combined denominator is:

```text
10,000 (bps base) * 10,000 (multiplier base) = 1e8
```

Using `1e10` makes every documented multiplier 100x weaker. Consequently, even the project's operational default of `300_000`, nominally 30x, preserves only 0.3x of the raw oracle spread. Two fresh, correct feed observations whose confidence bands overlap can therefore produce non-overlapping executable pool quotes. A permissionless caller can cycle through those pools and extract the difference from LPs.

## Affected code

The same calculation appears in:

- `smart-contracts-poc/contracts/PriceProvider.sol`
- `smart-contracts-poc/contracts/PriceProviderL2.sol`
- `smart-contracts-poc/contracts/ProtectedPriceProvider.sol`
- `smart-contracts-poc/contracts/ProtectedPriceProviderL2.sol`

`AnchoredPriceProvider` uses the same shaping scale, but its final anchored-band clamp prevents this particular too-tight quote from escaping the configured outer band.

## Root cause

The oracle producers and their documentation define spreads as whole bps:

```solidity
// LazerConsumer
spreadU = Math.ceilDiv(10_000 * uint256(conf), pU);

// ChainlinkOracle
uint256 spread = Math.ceilDiv(uint256(BPS_BASE) * half, uint256(int256(price)));
```

The provider then computes:

```solidity
uint256 adjustedSpread = spread * confidenceParam;
uint256 delta = midPrice * adjustedSpread / 1e10;
```

The provider's own tests state that `confidenceParam = 10_000` is 1x. With that setting, a 500 bps oracle spread produces:

```text
delta / mid = 500 * 10,000 / 1e10 = 0.0005 = 5 bps
```

It should produce 500 bps. Thus, the implementation preserves only 1% of the reported spread at the documented 1x setting.

The maximum setting does not apply 100x as documented:

```text
500 * 1,000,000 / 1e10 = 5% = 500 bps
```

It merely passes the raw spread through at 1x.

## Attack path

Consider two providers for the same asset pair, both using fresh observations at the same timestamp:

```text
source A: mid = 100, spread = 500 bps, valid interval = [95, 105]
source B: mid = 104, spread = 500 bps, valid interval = [98.8, 109.2]
```

The intervals overlap, so both observations can be simultaneously correct; the attack does not require a stale, delayed, forged, or malicious oracle update.

With the repository's `300_000` operational confidence setting and an additional 10 bps margin, the production provider returns approximately:

```text
source A: bid = 98.4015,   ask = 101.6015
source B: bid = 102.33756, ask = 105.66556
```

The effective half-width is only about 160 bps, below the feeds' reported 500 bps. Since source B's bid is above source A's ask, an attacker can:

1. Swap quote token to base token through the low-price pool at source A's ask.
2. Swap base token back to quote token through the high-price pool at source B's bid.
3. Keep the difference while the pools' LPs absorb the loss.

This path is a normal permissionless exact-input multihop swap. No callback manipulation, partial fill, stale price, or privileged action is required.

## Impact

The real-router PoC starts with 100 quote tokens and ends with:

```text
100.719335540287460221 quote tokens
```

The attacker realizes `0.719335540287460221` tokens, or 71 bps, after real pool fees and bin traversal. The attack can be repeated or sized against available liquidity until pool slippage closes the discrepancy. This is direct LP loss above the contest's 0.01% Medium threshold.

The impact is bounded by available liquidity, fees, bin movement, and the difference between valid feed observations, so the demonstrated issue supports Medium rather than High severity.

## Proof of concept

The provider-level PoC deploys two production `PriceProvider` contracts, proves that fresh overlapping 500 bps bands are compressed below 200 bps, and shows that preserving the reported bands closes the cycle:

```bash
cd smart-contracts-poc
forge test --match-path test/PriceProviderSpreadUnitsMultiFeedPoC.t.sol -vv
```

The pool-level PoC takes those exact provider outputs through two real `MetricOmmPool` instances and `MetricOmmSimpleRouter`, including callbacks, fees, and bin transitions:

```bash
cd metric-periphery
FOUNDRY_OFFLINE=true forge test --match-path test/MetricOmmRouterMultiFeedSpreadPoC.t.sol -vv
```

PoC files:

- `smart-contracts-poc/test/PriceProviderSpreadUnitsMultiFeedPoC.t.sol`
- `metric-periphery/test/MetricOmmRouterMultiFeedSpreadPoC.t.sol`

## Scope and trust assumptions

The README marks the PriceProvider factory as trusted and says mis-tuned provider guards may cause bad execution. This finding does not rely on an attacker controlling that factory or selecting an out-of-envelope value:

- both oracle observations are fresh and internally consistent;
- `300_000` is the default applied to all providers by `script/l1/SetMagic.s.sol` and `script/l2/SetMagic.s.sol`;
- the contracts and tests explicitly describe `10_000` as 1x and `1_000_000` as 100x;
- the error is a disagreement between upstream whole-bps units and downstream multiplier arithmetic.

There is still judging risk if `confidenceParam` is interpreted as an arbitrary trusted quote-shaping knob despite those comments and defaults. The strongest framing is therefore a unit/implementation mismatch under the project's first-party configuration, not trusted-party misconfiguration.

## Recommendation

Make the units explicit and use a denominator consistent with whole-bps oracle spreads. If `10_000` remains the 1x multiplier base:

```solidity
uint256 constant CONFIDENCE_DENOMINATOR = 10_000 * 10_000; // 1e8
uint256 delta = Math.mulDiv(midPrice, spread * confidenceParam, CONFIDENCE_DENOMINATOR);
```

Use overflow-safe `Math.mulDiv` composition as needed, round asks upward and bids downward, and add tests asserting that:

- 500 bps at 1x produces a 500 bps half-width;
- the maximum 100x setting really produces 100x;
- two overlapping source bands cannot become crossed executable quotes solely because of scale conversion.

If the current arithmetic is intentional, rename and document `confidenceParam` with its actual units, correct the contradictory tests/scripts, and enforce a conservative minimum band that cannot be narrower than the oracle uncertainty intended by the protocol.
