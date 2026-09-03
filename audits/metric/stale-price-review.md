# Stale and outdated price review

## Scope interpretation

The trusted-oracle assumption should distinguish source authenticity from protocol consumption:

- Pyth/Chainlink prices and signed timestamps are assumed correct when produced.
- A caller cannot forge a price or timestamp.
- Protocol logic that replays, selectively composes, or derives state from an older authenticated observation can still be a bug.
- A finding that merely assumes the source stops updating or publishes an incorrect price conflicts with the README assumption.

The code also promises that swaps revert on stale prices under `MAX_TIME_DELTA` / `MAX_REF_STALENESS`. Therefore a protocol-side freshness bypass is in scope, although scenarios that use an observation inside the explicitly configured age window remain contest-risky.

## Finding 1: PriceVelocity swap activity erases elapsed price allowance

**Assessment: Medium candidate, 60-70% contest acceptance.**

`PriceVelocityGuardExtension.beforeSwap` unconditionally writes both `lastMidPriceX64` and `lastUpdateBlock` after reading the previous values. A same-price dust swap has zero measured price change and always passes, but still replaces the block timestamp. The next distinct correct oracle price is then compared as if no time had elapsed.

At a 10 bps cap, a 1% update normally passes after 99 elapsed blocks. The real-pool PoC proves that one dust swap at a newly refreshed unchanged quote discards those 99 blocks, causes the identical fresh 1% update to revert, and delays natural recovery by another 99 blocks. The extension runs before every swap, so both directions are unavailable.

This path uses no stale or incorrect oracle datum. It is stronger than the old same-block-ratchet formulation and is not the known oracle-shock cycle: the impact comes from corrupting extension timing state and rejecting the replacement observation.

Detailed report: [price-velocity-same-block-ratchet.md](vulnerabilities/price-velocity-same-block-ratchet.md)

PoC: `metric-periphery/test/extensions/PriceVelocitySameBlockRatchet.audit.t.sol`

## Finding 2: Synthetic providers compose individually accepted legs without a skew bound

**Assessment: Medium candidate, 30-45% contest acceptance.**

`AnchoredPriceProvider` checks each leg independently against `MAX_REF_STALENESS`, discards both returned reference times, and computes `baseMid / quoteMid`. It never checks `abs(baseRefTime - quoteRefTime)`.

Metric's Pyth ingestion accepts an arbitrary verified feed list, and Pyth Lazer subscriptions can request selected feed IDs. A caller can therefore push a newer correct BTC/USD observation while leaving ETH/USD at its prior correct observation. If both assets moved together, the coherent BTC/ETH ratio may be unchanged, but the provider quotes `BTC(t1) / ETH(t0)`.

The focused parser/provider PoC uses a 30-second interval under a 60-second bound. Both feeds are authentic and individually accepted; refreshing only BTC creates a 97 bps excess versus the coherent midpoint and a 100 bps excess versus the repaired provider bid. Pushing the correct ETH leg removes the discrepancy.

The primary invalidation risk is the README's broad statement that oracle updates are always not stale. The response is that both source observations are valid and inside the protocol's own freshness bound; the missing invariant is temporal coherence between legs. Judges may still classify the unsubmitted second leg as ordinary pull-oracle lag or the prior known oracle-lag/LVR issue, so this is not as clean as Finding 1.

PoC: `smart-contracts-poc/test/AnchoredSyntheticTimestampMismatchPoC.t.sol`

## Checked and not new findings

- **Single-feed Pyth:** uses signed per-feed `FeedUpdateTimestamp`, skips missing timestamps, rejects excessive future drift, and stores only strictly newer observations.
- **Single-feed Chainlink:** verifies DON reports, stores `observationsTimestamp`, rejects zero/excessive-future timestamps, and stores only strictly newer observations.
- **L1 providers:** reject reference time zero, any future second, and age greater than the configured maximum.
- **Millisecond-to-second flooring:** extends the effective boundary by less than one second. This is not Medium impact.
- **Pool callback update:** one pool swap reads bid/ask once before extensions and settlement. A Pyth update during its callback cannot reprice that same swap halfway through.
- **Old-price swap, push, reverse swap:** already covered by the prior oracle-lag/LVR disclosure and should not be submitted as a new finding.
- **L2 sequencer downtime:** current L2 providers lack a sequencer uptime/grace-period gate, but a prior audit already reported this class, so it is likely an ineligible duplicate.
- **Compressed-oracle shared timestamps and pusher replay:** require trusted publisher behavior or match acknowledged replay semantics/known issues; no new Medium was established.

## Recommended fixes

1. Track the block/time of the last distinct accepted PriceVelocity midpoint, not the last swap; do not advance it on zero movement, and keep one comparison baseline per EVM block.
2. For synthetic providers, retain both leg timestamps and reject when their absolute skew exceeds a dedicated small bound. Do not rely only on independent age checks against `block.timestamp`.
3. Preserve the existing per-feed timestamp, monotonicity, future-drift, and provider-age checks.
