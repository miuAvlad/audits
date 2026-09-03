# Economic Escalation: Oracle Report / Rebase Front-Running

> **Final bounty assessment: design-dependent and outside the protocol's assumed
> security boundary, not a confirmed High finding.** The tests quantify the economic
> effect if historical rewards are assumed to belong exclusively to holders present
> during the reported interval. Under the alternative protocol assumption that every
> share existing when a rebase executes participates in that rebase, the demonstrated
> behavior is part of the rebasing design. The High impact figures below are conditional
> stress results, not the final validity classification. Practical impact is further
> weakened by normal-report profitability, mixed historical/current configurations,
> and known-issue or duplicate risk from the Certora threat model.

## Result

- **Highest verified conditional impact:** `198.000338189593756252 ETH` direct native-ETH profit on a mainnet fork. This variant uses the intended production mint/burn bucket settings and exploits the live-TVL denominator to bypass the 25-bps positive-rebase cap.
- **Previous within-cap result:** `73.880571211828077294 ETH` direct profit using a single full `30,000 ETH` mint bucket and three normal withdrawal-finalization reports.
- **Impact mapping:** High — theft of material unclaimed yield.
- **Attacker permissions:** public deposit, permissionless `executeTasks()`, and public standard withdrawal NFTs; no oracle role, executor role, validator role, or whitelist. The PoC impersonates only the three honest committee members needed to publish an accurate report.
- **Condition:** the fork maximum requires a 25-bps positive report, which at the 5% APR bound requires an 18-day-6-hour reference interval. The full historical scan found no interval near that size; the largest positive interval was 2 days 10 hours 46 minutes.
- **Upper-bound unit scenario:** `192.230312948426274167 ETH` at 80,000 ETH capital, but that single-window deposit exceeds the currently deployed 30,000 ETH global mint bucket and must not be presented as current executable impact.
- **Secondary route:** a deployed-state instant stETH exit proves `7.436740256334184057 stETH`, but the public async route is fee-free and stronger.

### Verified live-TVL cap bypass

An accurate `26 bps` positive report over a 20-day reference interval passes the configured `500 bps` APR check, but initially reverts at the LiquidityPool's `25 bps` absolute cap. Both checks read TVL at execution time rather than at the report boundary.

For incumbent TVL `P`, reported fraction `r = 26 bps`, and cap `c = 25 bps`, the minimum attacker capital is:

```text
A >= P * (r / c - 1) = 0.04 * P
```

The post-consensus deposit increases live TVL until the unchanged report passes. At that minimum capital, the attacker's historical-reward capture is approximately:

```text
capture = A * R / (P + A) = P * (r - c) = 1 bp of incumbent TVL
```

Latest passing fork output:

```text
[PASS] test_liveTvlLetsAttackerBypassOriginalRebaseCapAndExtractExcessRewards()
mint-bucket deposit count:       3
mint-bucket elapsed seconds:     23,664 (6h 34m 24s)
attacker capital:                79,200.173737842916267432 ETH
reported rewards:                 5,147.946292959789557407 ETH
excess over original cap:           197.997934344607290669 ETH
captured historical rewards:        198.000338189593756252 ETH
normal finalization reports:           5
final native-ETH profit:             198.000338189593756252 ETH
```

The dedicated PoC restores the production upgrade settings that `TestSetup` deliberately makes unbounded for generic fork tests:

- mint: `30,000 ETH` capacity, `2.083333333 ETH/second` refill;
- burn: `25,000 ETH` capacity, `1.736111111 ETH/second` refill.

`executeTasks()` has no role modifier. After the earlier deposits consume/refill the global bucket, the attacker can privately bundle the last deposit with execution of the already-consensused report. Subsequent honest consensus reports finalize the ordinary withdrawal NFTs, while any address can execute those reports.

Run from the repository root:

```bash
MAINNET_RPC_URL="YOUR_MAINNET_RPC_URL" forge test \
  --match-path test/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol \
  --match-test test_liveTvlLetsAttackerBypassOriginalRebaseCapAndExtractExcessRewards \
  -vv
```

This is adjacent to the historical-reward capture finding, but its narrower root cause is that the safety cap itself uses mutable execution-time TVL. Before the attacker deposit the exact report provably reverts with `RebaseExceedsPositiveCap`; after the deposit it succeeds unchanged.

The main triage risks remain substantial:

- at the deployed `500 bps` APR limit, a `26 bps` accurate report needs roughly a 19-day reference interval; Ether.fi states operationally that rebases should remain below 24 hours;
- the production mint limiter makes the `79,200 ETH` entry visible over several hours, although the final threshold-crossing deposit and execution can be bundled;
- the June 2026 Certora threat model already lists large-deposit/execution bundles for risk-free yield, so the general reward-capture behavior may be considered known or intended;
- triage may treat using live post-deposit TVL as the intended meaning of “pre-rebase TVL,” despite the report being rejected relative to the historical reference state.

Therefore the PoC proves a conditional direct-theft impact above `198 ETH`, but it does not justify Critical severity. High is defensible only if the program accepts the stale-TVL cap bypass as distinct from known rebasing behavior and accepts a multi-week accurate catch-up report as realistic.



### Historical feasibility correction

The `73.88 ETH` result is a deployed-code stress case, not a historically observed operating condition. A scan of 3,755 executed mainnet reports found a maximum reference interval of 2 days 10 hours 46 minutes, carrying `222.55994380339993 ETH` of accrued rewards. Using the historical TVL and a counterfactual 30,000 ETH deposit gives approximately `5.182989 ETH` captured. See `ORACLE_REPORT_GAP_RESULTS.md` and `ORACLE_REPORT_GAPS.json`.

## Strongest flow: fee-free public withdrawal NFTs

```text
Delayed positive report reaches consensus
        |
        v
Attacker deposits at the pre-report eETH share rate
        |
        v
Normal authorized executor executes the report
        |
        v
New shares capture historical accruedRewards
        |
        v
Attacker creates ordinary public WithdrawRequestNFTs
        |
        v
Normal subsequent reports finalize the requests
        |
        v
Attacker claims ETH with no instant-exit fee
```

The standard withdrawal path removes the 10-bps stETH exit fee and the priority queue's whitelist. The attack only relies on the oracle continuing its normal report/finalization duties after the attacker submits valid public withdrawal requests.

### Upper-bound 80,000 ETH throughput unit PoC

The maximum-throughput test models:

- pre-attack TVL: `1,979,285 ETH`;
- liquid LP ETH: `14,559 ETH`; the attacker deposit itself raises this enough to fund the withdrawals;
- delayed positive rebase: `25 bps` after a 19-day report span;
- public attacker deposit: `80,000 ETH`;
- maximum withdrawal size: `1,000 ETH` per NFT;
- finalization limit: `80,000 ETH/day`; 
- report period: 1,280 slots and post-consensus wait: 50 slots.

The attacker receives `80,192.230312948426274167 eETH` after execution, then creates 81 standard withdrawal NFTs. Six ordinary reports finalize batches of at most 14 full requests, and all claims settle after roughly 26.6 hours.

```text
[PASS] test_oneDayThroughputExtractsOver192Eth()
attacker profit (ETH): 192.230312948426274167
```

The exact passing source is `my-audit/pocs/OraclePositiveRebaseAsyncExitMaxPoC.t.sol`.

### One-report variant

A smaller test uses `14,187 ETH` capital so all 15 requests fit in the very next report's rate limit:

```text
[PASS] test_delayedReportCaptureExitsFeeFreeAtNextReport()
attacker profit (ETH): 35.215087414069522922
```

The source is `my-audit/pocs/OraclePositiveRebaseAsyncExitPoC.t.sol`.

### Economic bound

For pre-attack TVL `P`, capital `A`, and positive-rebase fraction `r`, captured historical yield is:

```text
capture = A * r * P / (P + A)
```

At the modeled 25-bps report, total historical rewards are `4,948.2125 ETH`. Capture asymptotically approaches that amount as capital grows, but withdrawal latency and capital cost grow with the deployed 80,000 ETH/day finalization limit. The 80,000 ETH scenario is a concrete high-impact point, not the theoretical maximum.

At 5% annual capital cost, approximately one day on 80,000 ETH costs about 11 ETH, leaving the 192.23 ETH capture strongly profitable before gas. The PoC itself measures direct on-chain proceeds and does not subtract financing costs.

### Scope and operational caveats

The bounty impact table classifies theft of material unclaimed yield as High. These rewards accrued before the attacker deposit. The 80,000 ETH unit model demonstrates `192.23 ETH` of dilution, but it exceeds the current single-window mint limit and is not the deployed-state claim.

The exploit is conditional on a delayed positive report. Normal 4.27-hour reports merely front-load approximately one interval of yield while the attacker waits approximately one interval to exit, so the clean economic advantage is small or absent. A long report span creates the asymmetry.

Guardians could react by pausing deposits, blacklisting the attacker, or invalidating its still-pending requests. Those are discretionary off-chain responses, not automatic on-chain prevention. A private `executeTasks()` transaction is insufficient because the report and its mandatory waiting window are already public.

## Secondary path: instant stETH exit

```text
Positive report reaches consensus and reveals accruedRewards
        |
        v
Attacker deposits ETH at the old eETH share rate
        |
        v
Normal authorized executor executes the report
        |
        v
New shares receive part of rewards accrued before the deposit
        |
        v
Attacker instant-redeems the rebased eETH for stETH
```

The report accounts for a historical interval, but `LiquidityPool.deposit()` remains open after consensus. The deposit mints shares using pre-report TVL. `executeTasks()` then adds all historical `accruedRewards` to the pool, including the attacker's new shares in the distribution.

## Secondary stETH PoC

The PoC models production values observed on 31 July 2026:

- TVL: approximately `1,979,285 ETH`;
- stETH instant-exit fee: `10 bps`;
- stETH redeemable amount and bucket: `5,000 stETH`;
- acceptable rebase APR: `500 bps`;
- hard positive-rebase cap: `25 bps`;
- attacker deposit: `4,987 ETH`, so the rebased balance remains inside the bucket.

Output:

```text
[PASS] test_maxImpactAfterDelayedPositiveReport()
attacker profit (stETH): 7.436729711331158227
```

Economics:

```text
captured historical rewards: 12.4361658772 ETH
10-bps exit cost:             4.9994361659 ETH
net attacker profit:          7.4367297113 stETH
```

The tested source is `my-audit/pocs/OraclePositiveRebaseMaxImpactPoC.t.sol`. It was executed in a clean isolated snapshot of `b4a0968087b178bc346cdf6bee6c0597bf4c42c7` after being placed under `test/`.

## stETH route profitability threshold

For pre-attack TVL `P`, attacker deposit `A`, positive-rebase fraction `r`, and exit-fee fraction `f`:

```text
gross captured reward = A * r * P / (P + A)
net profit = (A + gross captured reward) * (1 - f) - A
```

At `P = 1,979,285`, `A = 4,987`, and `f = 0.001`, break-even is:

```text
positive rebase > 10.035231 bps
```

At the maximum accepted 5% annualized rate, this requires a report spanning about `7.326 days`. The 25-bps cap is reached after `18.25 days` at that APR.

A normal 1,280-slot report spans about 4.27 hours. A recent approximately `0.1153 bps` report would lose about `4.93 ETH` after fees at this attack size, so the path is not currently profitable under normal operations.

`EtherFiOracle.slotForNextReport()` can roll a delayed report over skipped report periods. The contracts therefore permit the long-span precondition, although it is an exceptional operational state.

## Relationship to the liquidity race

This is in the same temporal-gap family, but it is not exactly the same finding:

- liquidity invalidation: a public ETH redemption changes `totalValueInLp` and makes a consensused `finalizedWithdrawalAmount` non-executable;
- positive-rebase sandwich: a public deposit changes total shares before execution and captures historical rewards.

The original liquidity race remains a recoverable Low-severity liveness issue. The economic path should be submitted separately, or clearly labeled as a distinct economic variant. Using either economic result as impact of the liquidity DoS alone would overstate the causal link.

## Negative-rebase conclusion

No standalone profitable negative-rebase escape exists under the deployed values checked:

- maximum negative rebase: `3 bps`;
- ETH instant-exit fee: `30 bps`;
- stETH instant-exit fee: `10 bps`;
- current ETH instant-redeemable amount: `0` because the 1% TVL watermark exceeds liquid LP ETH;
- stETH redemption does not reduce `totalValueInLp`, so it cannot invalidate the withdrawal report.

Paying 10 or 30 bps to avoid at most 3 bps is loss-making. Timing helps a user already committed to exit, but does not produce autonomous attack profit.

## Priority queue conclusion

A second PoC showed roughly `0.020108 ETH` gross capture on a `900 ETH` deposit at the 5% APR ceiling for one normal report, followed by the one-hour priority exit.

This route is weaker because the requester must be whitelisted and Oracle Operations must fulfill the request. The March 2026 Certora audit records EtherFi's explicit trust assumption that malicious whitelisted activity is monitored and penalized. It should not be the primary bounty path.

## Recommended fix

Snapshot the rebase denominator at the report's reference boundary, or prevent deposits from participating in already-consensused historical rewards. A practical alternative is to execute reports atomically with publication/consensus finalization, leaving no public state-change window.
