# Eight-decimal synthetic-ratio flooring crosses the external bid and transfers LP principal

## Severity

**Medium**

The production-composed PoC uses fresh, correct `$1` USDC and `$100,000.01` cbBTC observations, a nonzero `1 bps` half-spread on each feed, the first-party `0.5 bps` Anchored-provider margin, and a `5 bps` pool notional fee. It values the trade at the conservative executable synthetic bid, not at the oracle midpoint.

Against a `$50m` one-sided LP position, the attacker earns `$58.53` after every quoted spread and pool fee, while the LP loses `$24,785`, approximately `4.96 bps`, of principal value. A full-precision control makes the identical trade unprofitable and leaves the LP profitable.

This exceeds the contest's `1 bp` and `$10` Medium thresholds. It is not High because profitability requires a low-ratio synthetic pair, sufficient one-sided liquidity, and a price close to a quantization boundary.

## Summary

`AnchoredPriceProvider` floors a two-feed ratio back to eight decimals before converting it to Q64.64:

```solidity
mid = Math.mulDiv(mid, ORACLE_DECIMALS, mid2);
```

For USDC/cbBTC at `$1 / $100,000.01`, the exact ratio is approximately:

```text
0.000009999999000000 cbBTC per USDC
```

Production first stores the ratio as the integer `999`:

```text
floor(1e8 * 1e8 / 100000.01e8) = 999
quoted midpoint                 = 0.00000999
relative underpricing          = approximately 9.999 bps
```

The subsequent Q64.64 conversion and outward band rounding cannot recover the discarded precision. Near the lower edge of this quantization bucket, the error exceeds the two oracle spreads, the configured margin, and the pool fee. The pool's fee-inclusive ask consequently falls below the conservative external bid implied by the same authenticated feed bands.

## Root Cause

The provider computes:

```text
mid8       = floor(mid0 * 1e8 / mid1)
quoted mid = mid8 / 1e8
```

It should preserve the ratio directly in the pool's Q64.64 representation:

```text
midX64 = floor(mid0 * 2^64 / mid1)
```

The factory bounds `minMargin`, staleness, and maximum spread, but it does not verify that the selected margin covers the price-dependent relative error introduced by `mid8`.

This is not merely the expected final Q64 rounding. It is an additional lossy eight-decimal normalization performed before Q64 conversion.

## Executable-Bid Economics

Each feed reports a `1 bps` half-spread. A conservative price at which the attacker can sell USDC for cbBTC is therefore:

```text
synthetic external bid = USDC bid / cbBTC ask
                       = 0.9999 / (100000.01 * 1.0001)
```

The PoC executes the following trade:

```text
USDC purchased:                         49,500,000.000000
cbBTC paid to vulnerable pool:                 494.90037510
cbBTC received at conservative bid:            494.90096040
attacker profit:                                  0.00058530 cbBTC
attacker profit in USD:                          $58.53
LP principal loss at external bid:           $24,785.01
LP principal loss:                         approximately 4.96 bps
```

The pool's `5 bps` notional fee is included in the attacker's payment. Because the fee is separated from the amount credited to the bin, an execution whose fee-inclusive price is already crossed reduces LP principal by more than the attacker's profit.

## Full-Precision Control

The PoC deploys a second production pool with identical tokens, liquidity, oracle observations, spreads, margin, fee, and bin configuration. Its only difference is a control provider that computes the synthetic ratio directly in Q64.64 before applying the same band.

For the identical exact-output trade:

```text
control attacker PnL: -0.49476093 cbBTC
control LP PnL:       +0.247248701890299652 cbBTC
```

Holding every external condition constant, removing the intermediate eight-decimal floor changes a profitable extraction into an approximately `$49,476` attacker loss and changes LP loss into approximately `$24,725` of LP gain. The LP outcome differs by approximately `$49,510`, or nearly the complete `9.9 bps` normalization error. This isolates the floor as the cause rather than ordinary market arbitrage.

## Attack Path

1. A pool selects an Anchored provider for a synthetic USDC/cbBTC ratio. `MetricOmmPoolFactory` does not impose address sorting, so this token orientation is valid when the provider exposes the matching pair.
2. Both approved feeds contain fresh, correct observations with ordinary nonzero uncertainty.
3. The cbBTC price enters a vulnerable portion of an eight-decimal ratio bucket.
4. The provider floors the ratio before constructing its bid/ask band.
5. The attacker exact-output buys USDC-side inventory from the pool.
6. The attacker sells or hedges the USDC at or above the conservative `USDC bid / cbBTC ask` price.
7. The attacker retains the crossed-price difference while the LP position contains less value at that same executable bid.

No stale price, malicious oracle, compromised role, custom extension, or mid-transaction oracle update is required.

## Price-Window Sensitivity

The previous `$100,001` example was not profitable against the executable bid and is no longer used.

For the parameters above, the production-pool PoC binary-searches the exact boundary after all integer rounding:

```text
vulnerable cbBTC/USD interval:       ($100,000, $100,000.12826601]
full `mid8 == 999` bucket:           ($100,000, approximately $100,100.1001]
profitable fraction of that bucket: approximately 0.128137%
```

The window is narrow, but it is a normal correct oracle state rather than oracle failure. An attacker can monitor feed updates and execute atomically when a signed observation enters it. The small per-dollar edge requires approximately `$8.5m` of affected inventory to produce `$10` of gross profit under this conservative configuration. The PoC uses `$50m` and produces `$58.53` of gross profit; net profitability still depends on gas and hedge execution.

This state dependency is why Medium, rather than High, is appropriate. Larger margins, larger spreads, or higher pool fees can close a given window, but `minMargin` is static while the relative quantization error changes with the synthetic ratio.

## Why Trusted-Role Assumptions Do Not Remove the Root Cause

The PoC does not use an out-of-envelope provider:

- The provider is created by the real `AnchoredProviderFactory`.
- The reference oracle is approved by that factory.
- `0.5 bps` is the margin used throughout the first-party Anchored tests.
- Both `1 bps` oracle spreads are included.
- The pool charges a nonzero `5 bps` notional fee.
- The pool is created by the real `MetricOmmPoolFactory` and registered through production `OracleBase` gates.

A trusted factory could configure a wider minimum margin, but the code does not derive or enforce the required margin from the resulting synthetic ratio. The report therefore relies on an accepted first-party configuration, not malicious trusted-role behavior.

## PoC Composition

`metric-periphery/test/extensions/OracleValueStopLossSyntheticRatioPrecision.audit.t.sol` deploys:

- the production `AnchoredProviderFactory`;
- the production `AnchoredPriceProvider`;
- the production `OracleBase` registration and attributed-read gates;
- the production `MetricOmmPoolFactory`, deployer, and pool;
- real `6`-decimal USDC and `8`-decimal cbBTC token behavior;
- a full-precision control pool.

The concrete oracle subclass only writes deterministic fresh data in place of signature verification. The contest assumes that authenticated oracle data is correct and fresh, and the vulnerability occurs after that data has already reached `OracleBase`.

The focused provider test is `smart-contracts-poc/test/AnchoredSyntheticRatioPrecision.audit.t.sol`.

```bash
cd smart-contracts-poc
FOUNDRY_OFFLINE=true forge test \
  --match-path test/AnchoredSyntheticRatioPrecision.audit.t.sol -vv

cd ../metric-periphery
FOUNDRY_OFFLINE=true \
FOUNDRY_ALLOW_PATHS='["../smart-contracts-poc"]' \
forge test \
  --match-path test/extensions/OracleValueStopLossSyntheticRatioPrecision.audit.t.sol \
  -R 'smart-contracts-poc/=../smart-contracts-poc/' \
  -vv
```

## Recommendation

Preserve the synthetic ratio directly in Q64.64 and apply the band in that representation:

```solidity
uint256 midX64 = Math.mulDiv(mid, Q64, mid2);
uint256 bidX64 = Math.mulDiv(midX64, BPS_BASE_U - half, BPS_BASE_U, Math.Rounding.Floor);
uint256 askX64 = Math.mulDiv(midX64, BPS_BASE_U + half, BPS_BASE_U, Math.Rounding.Ceil);
```

Alternatively, reject synthetic providers unless their configured margin covers a documented price-dependent bound for the intermediate representation. Direct Q64 composition is preferable because it removes the avoidable precision loss instead of charging every user a permanently wider spread.
