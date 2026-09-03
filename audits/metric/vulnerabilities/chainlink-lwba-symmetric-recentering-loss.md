# Symmetrizing Chainlink liquidity-weighted bid and ask around the benchmark can misprice pool trades

## Severity

**Medium**

`ChainlinkOracle` authenticates and decodes three economically distinct Data Streams
fields, but reduces them to a benchmark midpoint plus one symmetric spread. If the
benchmark is not exactly the arithmetic midpoint of the liquidity-weighted bid and
ask, the conversion shifts both executable edges. A permissionless trader can select
the unsafe direction and trade against LP inventory at a price better than
Chainlink's corresponding directional impact price.

The displacement can exceed the contest's 1 bp Medium principal-loss threshold during
a valid asymmetric market state. Chainlink's own stable-market example leaves about
4.84 bps of directional overpayment after a 10 bps provider margin and a 5 bps
notional fee. This report should remain Medium: no signed report proving a greater-
than-1% executable loss has been captured, and two signed samples in the repository
are protected by the whole-bps ceiling.

## Summary

Chainlink Data Streams v3 and HFS reports contain a benchmark `price`, a
liquidity-weighted `bid`, and a liquidity-weighted `ask`. Production converts them
as follows:

```solidity
d.price = _toMid8(r.price);
d.spread0 = _spreadFromBidAsk(r.price, r.bid, r.ask);

function _spreadFromBidAsk(int192 price, int192 bid, int192 ask)
    private pure returns (uint16)
{
    require(price > 0 && ask >= bid, InvalidReportPrice());
    uint256 half = uint256(int256(ask) - int256(bid)) / 2;
    uint256 spread = Math.ceilDiv(uint256(BPS_BASE) * half, uint256(int256(price)));
    return (spread > BPS_BASE ? uint256(BPS_BASE) : spread).toUint16();
}
```

`AnchoredPriceProvider` later reconstructs a symmetric band around `d.price`:

```solidity
uint256 half = spreadBps * ONE_BPS_E18 + minMargin;
uint256 refBid = _bandEdge(mid, BPS_BASE_U - half, Math.Rounding.Floor);
uint256 refAsk = _bandEdge(mid, BPS_BASE_U + half, Math.Rounding.Ceil);
```

This preserves approximately the original `ask - bid` width but discards where that
width was located relative to the benchmark. Width preservation is insufficient for
directional execution safety.

## Chainlink Field Semantics

Chainlink documents the v3 fields independently:

- `price`: DON consensus median price;
- `bid`: simulated buy impact price at the configured liquidity depth;
- `ask`: simulated sell impact price at the configured liquidity depth.

Chainlink also explains that immediate transactions execute against bid or ask, not
against a midpoint, and that the two liquidity-weighted sides are produced from the
liquidity available on each side of order books:

- https://docs.chain.link/data-streams/reference/report-schema-v3
- https://docs.chain.link/data-streams/concepts/liquidity-weighted-prices

The report schema does not promise:

```text
price == (bid + ask) / 2
```

In particular, a DON consensus median and two independently liquidity-weighted
impact prices need not share one arithmetic center during asymmetric liquidity or
volatility.

## Root Cause

Let the authenticated report contain:

```text
P = benchmark price
B = liquidity-weighted bid
A = liquidity-weighted ask
H = (A - B) / 2
M = (A + B) / 2
```

Ignoring conservative integer rounding and minimum margin for clarity, production
stores `H / P` as a spread and reconstructs:

```text
Metric bid = P - H
Metric ask = P + H
```

Compared with the original directional fields:

```text
Metric bid - B = P - M
Metric ask - A = P - M
```

Both edges are shifted by the same center displacement.

- If `P > M`, `Metric bid > B`: the pool pays too much to traders selling the base
  asset.
- If `P < M`, `Metric ask < A`: the pool sells the base asset too cheaply.

Whole-bps rounding must be included in the trigger condition. Define:

```text
D = 10_000 * abs(P - M) / P
h = 10_000 * H / P
q = ceil(h) - h
```

All values above are in bps. The provider edge becomes unsafe when:

```text
D > q + providerMargin
```

and remains economically exploitable when the excess also clears the notional fee,
the active bin's added fee/price impact, and transaction costs. The previous, simpler
condition omitted `q`. The ceiling can fully protect a particular report, but it adds
less than 1 bp and therefore cannot generally restore the discarded directional
center.

## Economic Example

Chainlink's stable-market example provides this order book:

```text
best bid = 0.99
best ask = 1.00
LWBA bid = 0.981
LWBA ask = 1.005
```

Chainlink separately explains on the same page that the order-book Mid is the midpoint
between the best bid and best ask. The implied tuple is therefore:

```text
P = 0.995
B = 0.981
A = 1.005
M = 0.993
H = 0.012
D = 20.1005 bps
h = 120.6030 bps
stored spread = ceil(h) = 121 bps
rounding cushion q = 0.3970 bps
```

This spread is below the representative `150 bps` majors cap used in the repository,
so it is not rejected by `MAX_SPREAD_BPS`. With the representative envelope's maximum
`10 bps` provider margin:

```text
reconstructed Metric bid = 0.995 * (1 - 0.0121 - 0.0010)
                         = 0.9819655
source LWBA bid          = 0.9810000
edge overpayment         = 9.8420 bps relative to B
```

After a `5 bps` exact-input notional fee, the seller receives:

```text
0.9819655 * (1 - 0.0005) = 0.98147451725
residual overpayment     = 4.8371 bps relative to B
```

That is above the contest's 1 bp Medium threshold. A trade of approximately `$20,700`
at that rate transfers more than `$10` of value. It requires low/zero added sell fee
in the active bin and enough LP inventory, but does not require an exotic provider
cap, a malicious role, a stale report, or a compromised oracle.

This remains an illustrative Chainlink scenario rather than a captured signed report.
That distinction is the finding's main evidentiary limitation.

## Signed-Report Invalidation Check

The repository contains one authentic signed v3 testnet report and one authentic
signed HFS report. Both prove that `P != M` occurs in real data, but neither is unsafe:

| Sample | Half-width `h` | Center displacement `D` | Ceiling cushion `q` | Result before margin |
| --- | ---: | ---: | ---: | --- |
| v3 | 1.453388 bps | 0.083950 bps | 0.546612 bps | both reconstructed edges contain the source edges |
| HFS | 0.148106 bps | 0.043716 bps | 0.851894 bps | both reconstructed edges contain the source edges |

This does not disprove the root cause; it proves the trigger is conditional and that
the ceiling cannot be ignored. A stronger submission would attach a signed report
for which `D > q + margin + fees + 1 bp`.

## Attack

1. Chainlink publishes a fresh, correctly signed v3 or HFS report in which the
   benchmark is displaced from the arithmetic center of the liquidity-weighted bid
   and ask.
2. Any account submits the report through the permissionless `updateReport` path.
   `VerifierProxy` authenticates it normally.
3. `ChainlinkOracle` discards the directional center and stores only the benchmark
   plus half the total width.
4. `AnchoredPriceProvider` reconstructs symmetric edges around the benchmark.
5. A trader already holding the input asset compares the reconstructed edges with the
   report's original bid and ask, then swaps only in the favorable direction.
6. The pool exchanges LP inventory at the shifted edge. Marked at Chainlink's
   corresponding directional execution value, the LPs receive less value than they
   paid and the trader captures the difference.

The trader does not choose the report values, compromise Chainlink, control a
provider, require stale data, or invoke a custom extension. The permissionless action
is selecting when and in which direction to trade after a valid asymmetric report
has been stored.

This report does not prove that the reconstructed bid crosses the external ask, or
vice versa, so it should not claim a zero-inventory atomic arbitrage. The demonstrated
loss requires trader inventory (or separate sourcing/hedging) and sufficient pool
depth. That constraint is compatible with Medium but is a meaningful judging risk.

## Why Fees and Extensions Do Not Correct It

The pool converts the provider bid and ask into a geometric midpoint and spread fee.
That conversion faithfully reproduces the provider's reconstructed edges; it cannot
recover the original Chainlink edges that were discarded one contract earlier.

For reconstructed edges `B'` and `A'`, the pool computes:

```text
G = sqrt(B' * A')
f = A' / G - 1
```

At zero bin distance with no added bin fee, the marginal sell rate is
`G / (1 + f) = G^2 / A' = B'`, while the marginal buy rate is
`G * (1 + f) = A'`. The geometric conversion therefore propagates rather than
neutralizes the shifted provider edges.

- The oracle-derived base fee represents width, while the defect is center
  displacement.
- `spreadFeeE6` only allocates a portion of the charged spread between LP balances
  and fee recipients; it does not add a second protective spread.
- The separate notional fee reduces profit but is not sized from `abs(P - M)`.
- Price guard validates the stored benchmark, not preservation of directional bid
  and ask.
- PriceVelocity and stop-loss extensions consume the same reconstructed provider
  quote and therefore cannot distinguish it from the original report.
- The root cause does not itself guarantee a profitable multihop or cross-market
  round trip; the Medium impact is the directional value transfer against existing
  trader inventory.

## Contest-Assumption Analysis

This issue does not claim that Chainlink is malicious, incorrect, delayed, or stale.
It assumes all three authenticated report fields are correct according to their
documented meanings. The loss arises because protocol code treats independent
directional impact prices as if they were a symmetric confidence interval around a
different benchmark statistic.

The main submission risk is evidence, not oracle trust. The official stable-market
example proves a normal bounded tuple can cross Medium, and real signed repository
samples prove that benchmark/LWBA center displacement exists. However, neither signed
sample crosses the complete trigger condition. This supports an arguable Medium
submission, not High.

## Existing Test Coverage Gap

The generic `ChainlinkOracle.t.sol` fixture is symmetric around the benchmark:

```text
price = 150.0
bid   = 149.7
ask   = 150.3
```

That fixture makes `P == M`, so the directional-information loss is invisible. The
repository's separate real-data test contains asymmetric signed reports, but only
asserts the normalized midpoint and spread; it does not compare the reconstructed
provider edges against the original directional fields.

The focused audit regression is:

```text
smart-contracts-poc/test/oracles/ChainlinkLwbaRecentering.audit.t.sol
```

It proves both the 4+ bps residual error in Chainlink's stable-market example and the
non-triggering result for the two signed samples. Run it with:

```bash
FOUNDRY_OFFLINE=true forge test \
  --match-path test/oracles/ChainlinkLwbaRecentering.audit.t.sol -vv
```

## Recommendation

Do not use half of the total bid/ask width as a symmetric confidence value around an
independent benchmark.

If the current one-spread representation must be retained, validate
`bid <= price <= ask` and store the conservative maximum directional deviation:

```solidity
uint256 bidDeviation = uint256(int256(price) - int256(bid));
uint256 askDeviation = uint256(int256(ask) - int256(price));
uint256 maxDeviation = Math.max(bidDeviation, askDeviation);
uint256 spread = Math.ceilDiv(BPS_BASE * maxDeviation, uint256(int256(price)));
```

This produces a symmetric band that cannot be tighter than either original
directional edge. A better redesign preserves separate bid-side and ask-side
deviations through `OracleData`, provider band construction, and pool execution.
