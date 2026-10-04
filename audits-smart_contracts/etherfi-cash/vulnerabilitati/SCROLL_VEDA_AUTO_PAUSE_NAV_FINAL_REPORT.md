# Scroll Veda auto-pauses: NAV reconstruction and EtherFi impact

## Executive conclusion

The investigation found **four automatic pauses, one per Accountant, and no
manual pauses**. Every automatic pause was an upper-bound violation caused by
Scroll catching up from an old deployment/default rate to a rate that had
already been published by the corresponding canonical Ethereum Accountant.

No historical paused rate was low. No paused rate was replaced as erroneous:

- Veda directly unpaused each Accountant without changing its rate;
- liquidETH's first later update repeated the paused rate exactly;
- the other three later rates increased by only `0.001487%` to `0.010228%`;
- each Scroll paused rate exactly matched a prior Ethereum Accountant update;
- Scroll supply of every affected share token was zero during its pause.

The BoringVault architecture does not expose `totalAssets()` or an enumerable
position registry, so an independent mark-to-market or immediately redeemable
NAV cannot be completely reconstructed from public chain state. The evidence
does, however, strongly reject the hypothesis that any of these four events was
a transient wrong-rate incident.

**Final classification: C — Low/design risk.** EtherFi's use of `getRate()`
instead of `getRateSafe()` is a real circuit-breaker integration mismatch. A
financial exploit remains conditional on a separate materially wrong NAV being
published. No such event was found.

The fact that the pauses predated Cash is **not** used to invalidate the
prospective issue. It only proves there was no historical EtherFi victim. The
same pause state can recur after deployment; if it recurs because of another
correct cross-chain catch-up, it causes no mispricing, while a genuinely wrong
rate could cause wrongful liquidation.

## Reproducible evidence

The extraction program is
[`extract_scroll_veda_pauses.py`](../scripts/audit/extract_scroll_veda_pauses.py).
Its generated result is
[`scroll_veda_auto_pauses.json`](data/scroll_veda_auto_pauses.json).

Run:

```bash
python3 scripts/audit/extract_scroll_veda_pauses.py \
  --output my-audit/data/scroll_veda_auto_pauses.json
```

The script:

1. paginates the complete log history for all four Accountants through Scroll's
   public Blockscout API;
2. separates explicit `Paused()` events from automatic pauses, which emit only
   `ExchangeRateUpdated` followed by `Unpaused`;
3. independently verifies every candidate using archive `accountantState()`
   calls at `block - 1` and `block`;
4. reconstructs the active bounds, delay, exact violated condition, unpause,
   and first later update;
5. finds the matching canonical Ethereum Accountant update.

The explorer is therefore only a log index. Pause classification and stored
rate are proven against Scroll archive state.

## Complete auto-pause table

`Accounting NAV` below means the official Veda-published rate. It is not
silently equated with independent fair or immediately redeemable value.

| Asset | Block / date | Old rate | Paused rate | Trigger / active bound | Best accounting-NAV evidence | Independent fair NAV | Immediately redeemable value | Deviation | First subsequent rate | Likely wrong? | EtherFi exposed? | Potential historical impact |
|---|---|---:|---:|---|---|---|---|---|---:|---|---|---|
| liquidETH | `14,052,291` / 2025-03-16 02:51:21 UTC | `100000000` | `1048974799398492415` | Upper; max `100500000`; 6h delay satisfied | Ethereum had already published exactly `1048974799398492415` | Not fully reconstructable | Not measurable; Scroll supply was zero | `0%` versus canonical accounting NAV; independent deviation unknown | Same exact rate | No; decimal-scale initialization synchronization | No | None |
| liquidUSD | `14,090,187` / 2025-03-18 06:31:03 UTC | `1063549` | `1085269` | Upper; max `1068866`; 6h delay satisfied | Ethereum had already published exactly `1085269` | Not fully reconstructable | Not measurable; Scroll supply was zero | `0%` versus canonical accounting NAV; independent deviation unknown | `1085380` (`+0.010228%`) | No evidence; catch-up synchronization | No | None |
| liquidBTC | `14,107,745` / 2025-03-19 06:57:44 UTC | `100000000` | `101423242` | Upper; max `100500000`; 6h delay satisfied | Ethereum had already published exactly `101423242` | Not fully reconstructable | Not measurable; Scroll supply was zero | `0%` versus canonical accounting NAV; independent deviation unknown | `101424750` (`+0.001487%`) | No evidence; catch-up synchronization | No | None |
| eUSD | `14,108,040` / 2025-03-19 07:18:44 UTC | `1032917217867783877` | `1045066585449073893` | Upper; max `1038081803957122796`; 6h delay satisfied | Ethereum had already published exactly `1045066585449073893` | Not fully reconstructable | Not measurable; Scroll supply was zero | `0%` versus canonical accounting NAV; independent deviation unknown | `1045171147887171908` (`+0.010005%`) | No evidence; catch-up synchronization | No | None |

At every pause the configuration was:

```text
allowedExchangeRateChangeUpper = 10050  (+0.5%)
allowedExchangeRateChangeLower =  9950  (-0.5%)
minimumUpdateDelayInSeconds    = 21600  (6 hours)
```

The delays since the prior Scroll updates were 58.40 days, 60.54 days, 8.52
days, and 60.51 days respectively. None was a minimum-delay violation, and no
lower-bound pause occurred.

## Why the pauses occurred

### Canonical Ethereum-to-Scroll synchronization

The same vault and Accountant addresses exist on Ethereum and Scroll. Each
paused Scroll value had already appeared as an ordinary Ethereum update:

| Asset | Canonical Ethereum transition | Ethereum tx | Time before Scroll sync |
|---|---:|---|---:|
| liquidETH | `1048915581681286461 -> 1048974799398492415` (`+0.005645%`) | [`0x5d1a…d9d1`](https://etherscan.io/tx/0x5d1a3aaaea647d5d276b0115c4ab76ad00d03549975b6c2c9550d26da638d9d1) | 11,290 seconds |
| liquidUSD | `1085249 -> 1085269` (`+0.001843%`) | [`0x5dbb…df07`](https://etherscan.io/tx/0x5dbb8670c966406dbd4c794c9e76a9a5a1da37c57118aa2cc75375c67fb2df07) | 23,548 seconds |
| liquidBTC | `101417847 -> 101423242` (`+0.005319%`) | [`0x12e5…76b3`](https://etherscan.io/tx/0x12e5e4e35c6a14d03982e4a8556b0c79820e63adda93c3c46aa05e28694076b3) | 35,109 seconds |
| eUSD | `1044981371187451701 -> 1045066585449073893` (`+0.008155%`) | [`0x47bf…7262`](https://etherscan.io/tx/0x47bf407349a46ea0efbed9b42b823be4e1e1b50d44db0b1d11a03ac9ee267262) | 36,741 seconds |

Those Ethereum transitions were tiny and inside ordinary bounds. Scroll paused
because its local reference rate had not followed the canonical chain for days
or months—not because the source update itself represented a sudden 1-2% NAV
move.

### Asset-specific interpretation

- **liquidETH:** its Scroll Accountant was initialized with `100000000` while
  its WETH base uses 18 decimals. The first real synchronization changed scale
  to `1.048974799398492415 WETH/share`. Scroll supply was zero. This is an
  initialization-scale artifact, not evidence that the new rate was wrong.
- **liquidBTC:** the untouched Scroll deployment rate was `1.00000000`; the
  canonical rate had accumulated to `1.01423242` over 8.52 days.
- **liquidUSD and eUSD:** each Scroll mirror had been inactive for about 60.5
  days. Their 2.04% and 1.18% apparent jumps were accumulated catch-up changes.

## Correction and incident evidence

| Asset | Unpause tx | Duration | First post-unpause update | Result |
|---|---|---:|---|---|
| liquidETH | [`0xcddf…04b8`](https://scrollscan.com/tx/0xcddf84db9b1e719f6c48823ce7a259127ad8b9e7061e7bdb9d5c002a7a5604b8) | 413s | [`0xded3…5426`](https://scrollscan.com/tx/0xded361fdb01b2b54bb9b92a3d740b261d1d35c9f9253e86fde20b8c8200c5426) | Exact paused rate repeated |
| liquidUSD | [`0x8663…6372`](https://scrollscan.com/tx/0x8663cf3f653163a25dfb4464f5659f3384214744ebd5f6378a2f7683aa266372) | 60s | [`0xc820…f572`](https://scrollscan.com/tx/0xc82080b4edc4897bcbec553c0d48af024f1225488d4d1b1f46866ae5c7f1f572) | `+0.010228%` |
| liquidBTC | [`0xdda5…0cce`](https://scrollscan.com/tx/0xdda5cb8d5fc0843d2edea69dc294824161fd7092da118fa1aecd93297e810cce) | 14s | [`0xb97c…74c`](https://scrollscan.com/tx/0xb97c978ea56ea501d4ac3a058387335341b403581a1180a032e04665b486874c) | `+0.001487%` |
| eUSD | [`0x6aba…66fa`](https://scrollscan.com/tx/0x6aba67e5b574fd754704ac57ead33991e6bbde777dfe894e513ff108481a66fa) | 11s | [`0x2eb8…cc58`](https://scrollscan.com/tx/0x2eb8728b1d8f5b50c353186de4966237b4b4c424b7880c58bdedaab66074cc58) | `+0.010005%` |

No `Paused()` event exists in any history. There is one `Unpaused()` per
Accountant, and archive state proves each relevant rate update changed
`isPaused` from false to true. No subsequent reversal, incident correction, or
second automatic pause was found.

This is evidence that Veda treated each numeric rate as acceptable after human
review. It is not conclusive proof of economic NAV because `unpause()` contains
no on-chain validation requirement.

## Limits of independent NAV reconstruction

[`BoringVault`](https://github.com/Se7en-Seas/boring-vault/blob/main/src/base/BoringVault.sol)
is not an ERC-4626 vault. It exposes neither `totalAssets()` nor
`convertToAssets()`, and its manager can place value in lending positions, LPs,
Pendle positions, receipt tokens, and subvaults. Ordinary ERC-20 balances are
therefore only a small fraction of assets and cannot produce complete NAV.

For example, at the corresponding Ethereum blocks:

- liquidETH had `148,312.560795495772974362` shares. Identified direct WETH,
  eETH, weETH, and wstETH represented about `518.226637090472657773 WETH`, only
  `0.333%` of the value implied by accounting NAV;
- liquidBTC had `440.99103658` shares. Identified direct WBTC, eBTC, LBTC, and
  cbBTC represented `10.49883394 WBTC`, only `2.347%` of implied value.

The remainder was deployed in non-enumerable strategies. EtherFi's official
documentation lists these strategy classes for
[liquidETH](https://etherfi.gitbook.io/etherfi/liquid/eth-yield-vault) and
[liquidBTC](https://etherfi.gitbook.io/etherfi/liquid/liquid-btc-yield-vault).

An independent immediate-redemption quote is also unavailable:

- Scroll supply was zero at all four pauses;
- Teller and queue output pricing ultimately consumes the Accountant rate, so
  it would not be independent evidence;
- safe Teller paths revert while the Accountant is paused;
- queued redemption can include delay, deadline, and discount parameters and
  is not identical to mark-to-market NAV.

Accordingly, the honest classification is:

```text
official accounting NAV:     paused rate, corroborated cross-chain
independent mark-to-market:  unable to determine completely
immediate redeemable value:  unable to determine
evidence of wrong rate:      none
```

## EtherFi exposure timing

| Event | Scroll block | Date |
|---|---:|---|
| Last historical auto-pause | `14,108,040` | 2025-03-19 |
| PriceProvider and CashModule deployed | `14,206,947` | 2025-03-24 |
| DebtManager and SafeFactory deployed | `14,206,974` | 2025-03-24 |
| Four affected assets configured and enabled | `14,316,414` | 2025-03-30 |

The collateral configuration transaction is
[`0xff9e…87ec`](https://scrollscan.com/tx/0xff9ec652e7e7399cadfbfa5c193a18a69c819f46da8ee2ed42ef113a0b6a87ec).

At every historical pause, PriceProvider, DebtManager, CashModule, and
SafeFactory had no code, and the affected share token had zero Scroll supply.
Thus no Safe could hold it, owe debt against it, or be liquidated. No automatic
pause occurred after Cash deployment through the extraction snapshot.

Again, this answers only historical exposure. It does not prevent a future
automatic pause after deployment.

### Current prospective exposure

At Scroll block `34,620,182`, Cash had approximately `$20.855 million` of USDC
debt, so future liquidations are not merely a dead code path. However, the
available balance of every supported borrow token in DebtManager was zero, and
the approximate entire affected Scroll float was small:

```text
liquidETH: about $9,905
liquidUSD: about $9,106
eUSD:      about $73
liquidBTC: very small; its composed USD oracle reverted as stale at the snapshot
```

Thus a future false-low event could affect an existing borrower holding these
assets, but the current amount of exposed affected collateral is orders of
magnitude below total Cash debt. Supply and borrower composition can change,
so this is a snapshot rather than a permanent impact cap.

## Exact effect of a genuinely low wrong rate

EtherFi values collateral and tests liquidation as:

```text
reported collateral USD = shares * reportedPrice / 10^decimals
liquidatable when debt > reported collateral USD * liquidationThreshold
```

For debt `D`, reported price `Pw`, true price `Pt`, token decimals `d`, and
liquidation bonus `b`, `_getCollateralTokensForDebtAmount()` transfers:

```text
base shares transferred = D * 10^d / Pw
total shares transferred = base shares * (1 + b)
true value transferred   = D * (1 + b) * Pt / Pw
```

Compared with correct pricing, the share count is multiplied by `Pt / Pw`.
The excess true value is approximately:

```text
D * (1 + b) * (Pt / Pw - 1)
```

Current parameters are 70% threshold / 5% bonus for liquidETH and liquidBTC,
and 90% threshold / 2% bonus for liquidUSD and eUSD.

If a future paused rate were falsely 50% of true value, repaying `$1,000`
would transfer approximately:

- `$2,100` of true liquidETH/liquidBTC value;
- `$2,040` of true liquidUSD/eUSD value.

That would be direct user loss to a permissionless liquidator, and later rate
correction would not reverse the token transfer. But no historical event in
this investigation supplies the required `Pw << Pt` premise. Creating it in a
fork by impersonating the trusted updater proves only the downstream formula,
not a naturally reachable wrong-rate exploit.

The maximum demonstrated historical loss is therefore **zero**. The maximum
prospective loss is conditional on the amount of affected collateral held by
indebted Safes when a genuinely wrong rate occurs; at the inspected snapshot,
the total affected token float was only around `$19,000`, before excluding
tokens not held by indebted Safes.

## Opposite-conclusion test

The evidence supports the harmless-history hypothesis:

1. all pauses were upper-bound catch-ups, never dangerous low updates;
2. the exact rates already existed on canonical Ethereum;
3. the source-chain changes that produced them were ordinary `0.0018%` to
   `0.0082%` updates;
4. Veda unpaused without replacing the value;
5. later rates were unchanged or moved slightly upward;
6. no public correction or incident evidence was found;
7. zero Scroll shares existed, so no redemption discrepancy could affect a
   holder;
8. no EtherFi deployment existed during the windows.

What remains unproven is whether canonical accounting NAV exactly equaled full
mark-to-market or immediately redeemable value. That uncertainty cannot be
turned into a finding without affirmative divergence evidence.

## Final severity and invalidation reasons

**Supported severity: Low / design risk.** The integration bypasses the Veda
circuit breaker, but historical rates do not establish loss.

Reasons a stronger report should be invalidated or downgraded:

1. it equates an out-of-bounds update with an incorrect update;
2. it uses the inactive Scroll reference rate as fair NAV despite exact
   canonical Ethereum synchronization;
3. it assumes a low rate although all four observed updates were upward;
4. it treats Accountant rate, complete mark-to-market NAV, market price, and
   immediately redeemable value as equivalent;
5. it assumes a correction despite direct unpause and no rate reversal;
6. it claims historical Cash loss despite zero token supply and no deployed
   EtherFi contracts;
7. it demonstrates a low rate only by assuming malicious/incorrect updater
   behavior rather than finding a naturally occurring source.

The valid residual observation is narrower: EtherFi will consume a paused raw
rate in economic operations. If future evidence independently establishes a
materially wrong rate, this report's liquidation formula shows how that could
become an in-scope user-loss finding.
