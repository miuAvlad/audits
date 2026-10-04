# Historical Ether.fi Oracle Report Gaps

Scan date: 2026-07-31

## Result

The scan covered mainnet blocks `18,518,785` through `25,654,980` and found:

- 3,774 `ReportPublished` events;
- 3,755 `AdminOperationsExecuted` events;
- no positive historical reference interval at or above 18 days 6 hours;
- a maximum positive reference interval of 2 days 10 hours 46 minutes; and
- a maximum consensus-to-execution window of 1 day 19 hours 22 minutes.

The 18-day-6-hour threshold is the time required for a 25 bps positive report at the configured 5% annualized APR bound.

## Largest positive reference interval

- Executed: 2024-05-04 08:06:11 UTC
- Reference interval: 211,584 seconds, or 2 days 10 hours 46 minutes
- `accruedRewards`: 222.55994380339993 ETH
- Report hash: `0xca6dc3dc3318d11a7da593c84152fdf4ba616b3c84fe69235a0d5c7a23333e8b`
- Execution transaction: `0x683e4142748ba6b7ae7620a315f81ed0eb9cbb198ffd0d12cf9edf82cb74e628`
- Consensus-to-execution window: 648 seconds

The corresponding LiquidityPool `Rebase` event records post-rebase TVL of
1,258,436.428660605786234901 ETH. Subtracting the reported reward gives
pre-rebase TVL of 1,258,213.868716802386304901 ETH. The report was therefore
approximately 1.768856 bps, equivalent to about 2.6364% annualized over the
reference interval.

As a counterfactual using a 30,000 ETH post-consensus deposit, the historical
reward capture would be approximately:

`222.5599438 * 30,000 / (1,258,213.8687 + 30,000) = 5.182989 ETH`

This is not proof that the current 30,000 ETH rate limit and all current exit
conditions existed at that historical block. It is a scale estimate using an
observed honest report.

## Largest consensus-to-execution window

- Executed: 2025-01-22 19:32:35 UTC
- Window: 1 day 19 hours 22 minutes
- `accruedRewards`: 13.83883032989007872 ETH
- Execution transaction: `0x9ae1024abfe5e81a6d943547c91d6ba65d9c46bae83dc0afc55c9a98d9f842e8`

This confirms that the exploitable post-consensus window has historically
remained open much longer than the mandatory 50-slot delay. It does not by
itself establish large theft because this particular report carried a much
smaller reward.

## Implication for the finding

Historical data supports the existence of legitimate delayed positive reports
and long consensus-to-execution windows. It does not support the 18.25-day,
25-bps maximum-impact scenario as a historically observed operating condition.

The defensible framing is therefore:

- the accounting flaw and public attack window are technically reachable;
- a 2.45-day positive reporting interval has happened;
- the previously modeled 73.88 ETH result remains a conditional stress case;
- the historically grounded counterfactual is materially smaller, around
  5.18 ETH for the largest observed positive interval using 30,000 ETH.

## Reproduction

```bash
python3 my-audit/scripts/find_oracle_report_gaps.py \
  --rpc-url "$MAINNET_RPC_URL" \
  --blockscout-logs \
  --chunk-size 250000 \
  --decode-top-gaps 20 \
  --no-tvl \
  --top 20 \
  --json-out my-audit/ORACLE_REPORT_GAPS.json
```

Omit `--blockscout-logs` when using an archive RPC that supports large
historical `eth_getLogs` queries. Omit `--decode-top-gaps` to decode every
execution transaction.
