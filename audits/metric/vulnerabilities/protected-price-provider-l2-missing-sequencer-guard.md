# L2 provider trades without checking sequencer status or a recovery grace period

## Severity

Medium candidate

`ProtectedPriceProviderL2` only applies timestamp age and future-clock-tolerance checks. It has no sequencer uptime feed and cannot detect either an L2 sequencer outage or the immediate post-recovery interval.

This directly contradicts the repository invariant that swaps revert when the L2 sequencer is down. The strongest practical impact is at recovery: privileged actors able to use delayed-inbox or first-block ordering can trade before ordinary users regain equal access, instead of waiting through a grace period.

The issue requires a sequencer outage/recovery and a price-sensitive pool state, so it is weaker than the deterministic Chainlink FeeManager finding and should not be presented as High.

## Affected code

- `smart-contracts-poc/contracts/ProtectedPriceProviderL2.sol:38-42`
- `smart-contracts-poc/contracts/ProtectedPriceProviderL2.sol:132-151`
- `smart-contracts-poc/contracts/ProtectedPriceProviderL2.sol:201-229`
- `README.md:49`

## Root cause

The provider constructor accepts only a generic future-timestamp tolerance:

```solidity
uint256 public immutable MAX_TIME_DELTA;
uint256 public immutable FUTURE_TOLERANCE;
```

Its only L2-specific logic is:

```solidity
if (refTime > nowTs) {
    return (refTime - nowTs) > futureTol;
}
return (nowTs - refTime) > maxDelta;
```

There is no:

- sequencer uptime feed address;
- `latestRoundData()` call;
- `answer == 0` check;
- `startedAt` handling; or
- post-recovery grace period.

Therefore a price can pass all implemented checks while the sequencer feed reports down or has only just returned up.

## Explicit invariant violation

The contest README states:

```text
No trade on bad oracle: swaps revert on stale price
(maxTimeDelta/maxRefStaleness), excessive Chainlink deviation,
or (L2) sequencer down.
```

No other contract in the current swap path performs this check. `PythOracle` and `ChainlinkOracle` validate report timestamps, while the pool trusts the final bid/ask returned by its provider.

The local contract registry also contains earlier `PriceProviderL2` ABIs whose constructor accepted `_sequencerUptimeFeed` and exposed `sequencerUptimeFeed()`. This supports that sequencer protection was part of the intended L2 design rather than a new feature request.

## Recovery attack window

Chainlink's sequencer guidance explains that technically advanced actors may interact through the underlying rollup contracts while normal users lack standard L2 access, and recommends a grace period after recovery to restore fair access:

- [Chainlink L2 Sequencer Uptime Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds)

A representative flow is:

1. The sequencer goes down.
2. Normal LPs cannot use the standard RPC path to remove or rebalance liquidity.
3. Market conditions and the oracle price move during the outage.
4. The sequencer returns and processes privileged/delayed transactions before ordinary users regain equal access.
5. `ProtectedPriceProviderL2` accepts a quote immediately because it only checks the oracle timestamp.
6. A first actor trades against the pool's existing bin position before LPs receive any recovery window.

Depending on transaction ordering, the accepted observation may be either:

- the last observation that still falls inside `MAX_TIME_DELTA` after a short outage; or
- a fresh, correct post-recovery observation applied to inventory that users had no opportunity to adjust.

The second case does not rely on an incorrect oracle. The fairness/loss issue is that trading resumes with no grace period after asymmetric access.

## Base deployment relevance

Base is an announced deployment chain, and Chainlink publishes a Base mainnet sequencer uptime feed. The repository's Base provider config uses the L2 provider parameters (`maxTimeDelta` and `futureTolerance`) but supplies no uptime-feed or grace-period parameter.

`FUTURE_TOLERANCE` is not a substitute. It only handles clock skew between an oracle publication timestamp and `block.timestamp`; it says nothing about sequencer availability or how recently service recovered.

## Proof of concept

The PoC is in:

```text
smart-contracts-poc/test/ProtectedPriceProviderL2Sequencer.audit.t.sol
```

Run:

```bash
cd smart-contracts-poc
forge test --match-path test/ProtectedPriceProviderL2Sequencer.audit.t.sol -vv
```

Observed tests:

```text
[PASS] test_quotesWhileSequencerFeedReportsDown()
[PASS] test_quotesImmediatelyAfterRecoveryWithoutGracePeriod()
```

The tests demonstrate that sequencer state is completely disconnected from provider output. The second test sets recovery in the current block and the provider still returns a live bid/ask.

## Scope and limitations

This is not a stale-price or Chainlink round-completeness recommendation. It is an omitted check for a separately documented system state, and the README explicitly names that state as a no-trade invariant.

The severity caveat is practical exploitability:

- ordinary Base transactions generally cannot execute while the sequencer is fully unavailable;
- the financial impact depends on outage duration, market movement, pool inventory, and recovery ordering;
- if all observations are immediately updated and no actor has privileged access, direct loss may be absent.

For those reasons, this is a Medium candidate based on the explicit invariant and recovery-access asymmetry, not a fully unconditional Medium.

## Recommendation

Add immutable L2 sequencer configuration:

- a network-specific sequencer uptime feed;
- a nonzero recovery grace period;
- constructor validation for both values.

Before returning any quote:

1. Read `latestRoundData()` from the sequencer feed.
2. Revert when `answer != 0`.
3. Revert when the feed is uninitialized where applicable.
4. Revert until `block.timestamp - startedAt` exceeds the configured grace period.
5. Only then apply the existing oracle staleness and future-tolerance checks.

Add integration tests for sequencer down, exact recovery block, grace-minus-one, and grace elapsed.
