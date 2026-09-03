# Scroll PriceProvider ignores Veda Accountant pauses and V1 accepts zero rates

“When an exchange-rate update violates Veda's configured safety bounds, Veda automatically pauses the Accountant and its safe pricing interface stops exposing rates. EtherFi bypasses this state by consuming getRate(), allowing the out-of-bounds rate that triggered the pause to remain authoritative for collateral valuation and liquidation.”

## Executive conclusion

Two distinct conditions were investigated.

| Issue | Code defect | Naturally reachable prerequisite | Attacker can trigger it | Permissionless exploitation afterward | Final assessment |
|---|---|---|---|---|---|
| Paused Accountant rate is still consumed | Yes. EtherFi calls `getRate()` instead of the pause-aware getter. | Yes. All four deployed Accountants have historically auto-paused after an out-of-bounds update. | No. The update requires Veda's authorized updater. | Conditional. It additionally requires the stored rate to differ materially from realizable value and a usable borrow or liquidation path. | Confirmed integration/design defect; currently Low/design risk, not a demonstrated Medium/High exploit. |
| Generic `uint256` oracle returns zero | Yes in V1. The decoded value is not checked for zero. | Only after an effectively total vault loss, or an off-chain/updater error. | No. The final rate is supplied by the authorized updater. | Primarily denial of service; no profitable path was demonstrated. | Defense-in-depth omission; likely invalid as an independent Medium/High finding. |

The paused-rate hypothesis is materially stronger than generic staleness because
Veda has explicitly moved the Accountant outside its normal safety envelope.
Nevertheless, `isPaused == true` does **not** prove that the newly stored numeric
rate is false. Veda deliberately stores a legitimate large move and pauses so
that protected operations stop pending review.

The complete requested sequence is possible and is proven by a Scroll fork:

```text
old exchangeRate = X
authorized updater submits Y outside the configured bounds
isPaused becomes true
exchangeRate is updated to Y
getRateSafe() reverts
getRate() returns Y
EtherFi PriceProvider.price(token) returns Y
DebtManager consumes Y as collateral value
```

## Affected deployment

```text
Scroll PriceProvider proxy:  0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB
V1 implementation:           0x700a0b9bffc73e4e925e1cea0d4bf523f36369f6
DebtManager:                 0x0078C5a459132e279056B2371fE8A8eC973A9553
Authorized updater Safe:     0x560441fA211AEd16Dd49f70c226380c9D4875225
Updater threshold:           2 of 4
```

| Asset | Token | Accountant |
|---|---|---|
| liquidETH | `0xf0bb20865277aBd641a307eCe5Ee04E79073416C` | `0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198` |
| liquidBTC | `0x5f46d540b6eD704C3c8789105F30E075AA900726` | `0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0` |
| liquidUSD | `0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C` | `0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7` |
| eUSD | `0x939778D83b46B456224A33Fb59630B11DEC56663` | `0xEB440B36f61Bf62E0C54C622944545f159C3B790` |

## 1. Root cause in EtherFi

EtherFi's local Veda interface exposes only the unsafe getter in
[`ILayerZeroTeller.sol`](../src/interfaces/ILayerZeroTeller.sol):

```solidity
interface AccountantWithRateProviders {
    function getRate() external view returns (uint256 rate);
}
```

All four Scroll configurations deliberately encode `getRate()`:

- [`UpgradeMainnet.s.sol`](../scripts/gnosis-txs/UpgradeMainnet.s.sol) lines 229, 243, 257, and 271;
- [`PriceProviderSetTokenConfig.s.sol`](../scripts/PriceProviderSetTokenConfig.s.sol) lines 62, 76, 90, and 104;
- the later V2 configuration retains `GET_RATE_CALLDATA = 0x679aefce` in
  [`UpgradeToPriceProviderV2.s.sol`](../scripts/gnosis-txs/UpgradeToPriceProviderV2.s.sol).

V1's generic-oracle branch in
[`PriceProvider.sol`](../src/oracle/PriceProvider.sol) performs that call and
decodes the result without checking the Accountant's pause flag:

```solidity
(bool success, bytes memory data) =
    address(config.oracle).staticcall(config.priceFunctionCalldata);
if (!success) revert PriceOracleFailed();

if (config.dataType == ReturnType.Int256) {
    // positive-value check
} else {
    tokenPrice = abi.decode(data, (uint256));
}
```

V2 adds a zero-value check but retains the same `getRate()` integration and
still does not reject a paused Accountant. See
[`PriceProviderV2.sol`](../src/oracle/PriceProviderV2.sol) lines 297-317.

## 2. Exact `updateExchangeRate()` control flow

The deployed contracts match Veda's
[`AccountantWithRateProviders`](https://github.com/Se7en-Seas/boring-vault/blob/main/src/base/Roles/AccountantWithRateProviders.sol).

An update first requires an authorized caller and calls
`_beforeUpdateExchangeRate(newExchangeRate)`. That helper:

1. Reverts if the Accountant is already paused.
2. Reads the current timestamp, old exchange rate, and vault total supply.
3. Returns `shouldPause = true` if any of these strict conditions holds:

```solidity
currentTime < lastUpdateTimestamp + minimumUpdateDelayInSeconds

newRate > floor(oldRate * allowedExchangeRateChangeUpper / 10_000)

newRate < floor(oldRate * allowedExchangeRateChangeLower / 10_000)
```

If `shouldPause` is true, `updateExchangeRate()` does not revert. It executes:

```solidity
state.isPaused = true;
```

and skips fee calculation. Execution then continues through:

```solidity
state.exchangeRate = newExchangeRate;
state.totalSharesLastUpdate = uint128(currentTotalShares);
state.lastUpdateTimestamp = currentTime;
emit ExchangeRateUpdated(oldRate, newExchangeRate, currentTime);
```

Consequently, the rate that triggered the circuit breaker becomes the current
stored rate. Automatic pausing also does not emit `Paused()`; only the separate
administrative `pause()` function emits that event.

There are exactly three successful-update causes of automatic pause:

- the update is submitted too early;
- the new rate exceeds the upper bound;
- the new rate is below the lower bound.

An already-paused Accountant, failed authorization, or a reverting
`vault.totalSupply()` call reverts the update instead of producing this state.

### Legitimate and malicious causes

| Scenario | Interpretation |
|---|---|
| Correct rate submitted before the six-hour delay | Legitimate operational/timing error; the rate can be numerically correct. |
| Delayed updater publishes several days of accumulated NAV movement above 0.5% | Naturally reachable legitimate pause. Lateness itself is not checked, but the accumulated move violates the per-update bound. |
| Genuine gain, loss, volatility, or depeg moves NAV by more than 0.5% | Naturally reachable and explicitly anticipated by Veda. |
| Authorized updater submits a random or manipulated value | Trusted-updater compromise or misconduct. |
| Admin maliciously changes the bounds or delay | Trusted-admin behavior. |
| Updater submits gradual incorrect moves within the bounds | Trusted-updater behavior that may avoid pausing entirely. |

[Veda's Accountant documentation](https://docs.veda.tech/architecture-and-flow-of-funds/accountant)
explicitly says that too-early, too-large, and too-small updates store the rate
and pause. It also says that during extreme volatility, including a depeg, the
updater is expected to publish the rate even when that pauses the Accountant.

## 3. Live Scroll configuration

At the inspected Scroll snapshot, all four Accountants were unpaused and used
the same active controls:

| Asset | Current stored rate | Upper | Lower | Minimum delay | Paused |
|---|---:|---:|---:|---:|---|
| liquidETH | `1101880691051421124` | `10050` | `9950` | 21,600 seconds | No |
| liquidBTC | `103267583` | `10050` | `9950` | 21,600 seconds | No |
| liquidUSD | `1171348` | `10050` | `9950` | 21,600 seconds | No |
| eUSD | `1065720237279480362` | `10050` | `9950` | 21,600 seconds | No |

Thus a rate is permitted at the exact rounded bounds, while a value one unit
outside either bound pauses. The effective envelope is approximately `+0.5%`
and `-0.5%` per update, with at least six hours between updates.

The delay does not widen the bounds. If real NAV moves gradually by 0.6% while
the updater is unavailable, the next correct update is still outside the 0.5%
per-update envelope and pauses. No malicious role is needed to create that
state.

Only liquidBTC's bounds changed historically:

- upper `10000 -> 10050` in
  [transaction `0x7304...17b6`](https://scrollscan.com/tx/0x7304c7172de72bad4f71dd532960b4e7a9d2effe50994b1e27735da88d6617b6);
- lower `9900 -> 9950` in
  [transaction `0x0d7a...7349`](https://scrollscan.com/tx/0x0d7a39632056651a2b6629fad1f11bc06e0dd764889930651ae0f51c4bbd7349).

No delay changes were found.

## 4. Historical pauses prove natural reachability

A full reconstruction of `ExchangeRateUpdated`, `Paused`, `Unpaused`, and bound
events found one update-triggered pause for every deployed Accountant:

| Asset | Update block | Old rate | Stored new rate | Change | Delay since previous update | Paused duration |
|---|---:|---:|---:|---:|---:|---:|
| liquidETH | 14,052,291 | `100000000` | `1048974799398492415` | Decimal-scale initialization correction | 58.4 days | 413 seconds |
| liquidBTC | 14,107,745 | `100000000` | `101423242` | +1.423242% | 8.52 days | 14 seconds |
| liquidUSD | 14,090,187 | `1063549` | `1085269` | +2.042219% | 60.54 days | 60 seconds |
| eUSD | 14,108,040 | `1032917217867783877` | `1045066585449073893` | +1.176219% | 60.51 days | 11 seconds |

Transactions:

- liquidETH: [rate update](https://scrollscan.com/tx/0xd162170404874cf5d5b4be9c5e7cc5a052a548d42ce79f69202acc7ec9390ef2),
  [unpause](https://scrollscan.com/tx/0xcddf84db9b1e719f6c48823ce7a259127ad8b9e7061e7bdb9d5c002a7a5604b8);
- liquidBTC: [rate update](https://scrollscan.com/tx/0xd2ab8b61e2d92a6e693f1c06c87a614a537a962065180e7d59eca99e73633234),
  [unpause](https://scrollscan.com/tx/0xdda5cb8d5fc0843d2edea69dc294824161fd7092da118fa1aecd93297e810cce);
- liquidUSD: [rate update](https://scrollscan.com/tx/0x7bbc644478b9d85d1aa1941f3b6023298d3de26dc558f98568dbbc34a3cb6310),
  [unpause](https://scrollscan.com/tx/0x8663cf3f653163a25dfb4464f5659f3384214744ebd5f6378a2f7683aa266372);
- eUSD: [rate update](https://scrollscan.com/tx/0x92689556e9a61872799fd338131d6393a8623c33f328fbc9e381bd8228c88692),
  [unpause](https://scrollscan.com/tx/0x6aba67e5b574fd754704ac57ead33991e6bbde777dfe894e513ff108481a66fa).

For each update block, archive calls prove:

```text
accountantState.exchangeRate == event.newRate
accountantState.isPaused     == true
getRate()                    == event.newRate
getRateSafe()                == revert AccountantWithRateProviders__Paused
```

No manual `Paused()` event exists. Each `Unpaused()` event follows an
out-of-bounds update, which is the expected event pattern because automatic
pausing emits only `ExchangeRateUpdated`.

The complete histories contained 427 liquidETH, 434 liquidBTC, 460 liquidUSD,
and 489 eUSD rate updates. After the initial pause listed above, no later update
violated the active bounds or minimum delay. The longest later gaps were about
4.98 days, 21.99 days, 4.00 days, and 2.99 days respectively; a long gap alone
does not pause the Accountant when the eventual rate remains inside the
per-update envelope.

These events prove the prerequisite is real and does not require malicious
updater behavior. On-chain data cannot prove that each historical off-chain NAV
calculation was economically correct, but the long delay followed by a 1-2%
initial synchronization is a non-malicious explanation for liquidBTC,
liquidUSD, and eUSD.

### Critical historical limitation

The production Cash PriceProvider proxy was created at block `14,206,947` on
March 24, 2025. The last historical pause above occurred at block `14,108,040`
on March 19, 2025.

Therefore the PriceProvider did not exist during any of these four paused
windows and returned nothing at that time. The events prove future
reachability, not historical Cash exposure or loss.

No later auto-pause was found after Cash's PriceProvider deployment.

## 5. What Veda means by a paused rate

Veda exposes a deliberate raw/safe API split:

```solidity
function getRate() public view returns (uint256) {
    return accountantState.exchangeRate;
}

function getRateSafe() external view returns (uint256) {
    if (accountantState.isPaused) revert AccountantWithRateProviders__Paused();
    return getRate();
}
```

The quote getters follow the same model:

- `getRateInQuote()` returns a raw conversion;
- `getRateInQuoteSafe()` reverts while paused.

Veda's own economic consumers use the safe API. In the official
[`TellerWithMultiAssetSupport`](https://github.com/Se7en-Seas/boring-vault/blob/main/src/base/Roles/TellerWithMultiAssetSupport.sol),
both deposits and withdrawals use `getRateInQuoteSafe()`. The on-chain
withdrawal queue also uses the safe quote getter when pricing a new request.
Informational lens/helper paths may use the raw getters.

The intended semantics are therefore:

| Getter | Meaning |
|---|---|
| `getRate()` / `getRateInQuote()` | Return the latest stored value even when it is outside the configured trust envelope. |
| `getRateSafe()` / `getRateInQuoteSafe()` | Return a value approved for pause-sensitive economic operations. |

A paused rate is not necessarily numerically false. The same rate becomes
available through the safe getter immediately after an admin calls `unpause()`;
unpause does not require replacing or validating it on-chain. Pause is a
circuit-breaker and review state.

EtherFi nevertheless uses the raw value for collateral, borrowing, health, and
liquidation. That bypasses the safety policy Veda applies to its own Teller and
queue operations.

## 6. Fork proofs

The focused proof is
[`PriceProviderV1ScrollPausedRate.t.sol`](../test/price-provider/PriceProviderV1ScrollPausedRate.t.sol).

Run:

```bash
forge test \
  --match-path test/price-provider/PriceProviderV1ScrollPausedRate.t.sol \
  -vvv
```

Observed result:

```text
[PASS] test_HistoricalUpdatesStoredOutOfBoundsRatesAndAutoPausedAllFourAccountants()
[PASS] test_LivePriceProviderConsumesNewRateThatTriggersAccountantPause()
2 passed; 0 failed
```

The historical test forks immediately before and after each real update and
proves that the out-of-bounds rate was stored, the Accountant became paused,
the raw getter returned the new rate, and the safe getter reverted.

The live-path test forks Scroll block `34,613,218`, impersonates the actually
authorized updater Safe, and submits the first value one unit above the active
upper bound. It then proves atomically that:

```text
isPaused == true
exchangeRate == submitted rate
getRate() == submitted rate
getRateSafe() reverts
PriceProvider.price(liquidUSD) == submitted rate
DebtManager collateral value for one liquidUSD == submitted rate
```

Impersonating the authorized updater is used only to reach the same state
through the deployed authorization and update code. It does not claim that an
unprivileged attacker can trigger the pause.

## 7. Permissionless exploitation analysis

### What an attacker cannot do

An unprivileged actor cannot:

- call `updateExchangeRate()`;
- choose the submitted rate;
- pause or unpause an Accountant;
- delay the updater;
- change the bounds or minimum delay.

### What an attacker can do after an independent pause

An attacker can monitor update and state changes and act on an already-paused
Accountant. Veda-native deposits and new withdrawal pricing revert because the
Teller and queue use safe getters. Ordinary vault-share ERC20 transfers are not
disabled by the Accountant pause, so an attacker with existing shares, or one
who purchases them on a secondary market, can transfer them into an
attacker-controlled EtherFi Safe.

Cash counts the Safe's token balances as collateral and continues valuing them
through the raw paused rate. Relevant downstream paths are:

- collateral-to-USD valuation in
  [`DebtManagerCore.sol`](../src/debt-manager/DebtManagerCore.sol) line 375;
- liquidation-threshold checks at line 126;
- health enforcement at line 217;
- borrowing at line 461;
- permissionless liquidation at line 521;
- USD-to-collateral conversion in
  [`DebtManagerStorageContract.sol`](../src/debt-manager/DebtManagerStorageContract.sol) line 498.

Potential outcomes require an additional value discrepancy:

- paused rate materially above realizable value: excessive borrowing power and
  delayed liquidation;
- paused rate materially below fair value: premature liquidation and excessive
  collateral seizure;
- paused Teller makes shares temporarily illiquid: an attacker may buy shares
  at a secondary-market discount and collateralize them at NAV.

None follows merely from crossing the 0.5% bound. If the submitted rate is a
correct NAV, consuming it is not a collateral mispricing. At maximum LTV,
reported value must exceed realizable value by more than 25% for liquidUSD/eUSD
or 100% for liquidETH/liquidBTC to create immediate undercollateralization.

### Current blockers

At the inspected Scroll snapshot:

- all four Accountants were unpaused;
- DebtManager held zero balances of its supported borrow tokens;
- liquidUSD had zero normalized borrowing and zero supplier shares;
- its minimum initial shares was `type(uint128).max`;
- a normal new borrower therefore could not extract funds even if a paused-rate
  discrepancy existed.

Liquidators would receive paused Veda shares whose new Teller withdrawal and
new queue request paths are unavailable until unpause. That weakens immediate
realization of any alleged liquidation profit.

The integration can become permissionlessly exploitable after an independent
natural pause only if a report also demonstrates:

1. material divergence between stored NAV and realizable value;
2. available sound borrowing liquidity or a liquidatable victim;
3. a usable EtherFi Safe and spending/settlement route;
4. completed attacker profit or material protocol bad debt.

Those conditions were not demonstrated in the present deployment.

## 8. Separate V1 zero-`uint256` investigation

### Rate provenance

`AccountantWithRateProviders` does not calculate NAV from on-chain assets or
supply. Veda calculates the final share rate off-chain, and the authorized
updater directly supplies it as `uint96`:

```text
vault positions and off-chain valuation
  -> authorized updater calls updateExchangeRate(uint96)
  -> Accountant stores that exact uint96
  -> EtherFi calls getRate()
```

If a positive-rate Accountant receives `updateExchangeRate(0)`, zero violates
the lower bound. The Accountant pauses but still stores zero. `getRateSafe()`
then reverts while `getRate()` returns zero. V1 decodes that zero without an
`InvalidPrice` check because all four integrations are non-stable `uint256`
oracles.

### Can zero arise naturally?

| Candidate cause | Result |
|---|---|
| Scroll or global share supply becomes zero | Does not update the rate. The contract never divides assets by supply; it retains the last submitted rate. |
| Empty deployment | Uses a constructor-supplied starting rate. Zero would be privileged deployment misconfiguration. |
| Underlying on-chain `rateProviderData` returns zero | Does not alter `exchangeRate`. These providers are used by quote getters and fee claims, not by `updateExchangeRate()`. A zero quote rate normally causes division by zero. |
| Underlying provider reverts or is stale | Does not alter `exchangeRate`; the old submitted value remains. |
| Off-chain price dependency fails | No published evidence shows that Veda converts failure to zero. Signing zero would be an off-chain updater/oracle failure. |
| Arithmetic rounding | Reaches zero only when value per share is below one atomic unit of the base asset—an effectively total loss. |
| Base asset depegs in USD | Does not necessarily zero the Accountant rate because rates are denominated in WETH, WBTC, USDC, or USDe per share, not directly in USD. |
| Zero assets with outstanding shares | A correct NAV-per-share rate can be zero after an effectively complete loss of all backing assets. |
| Migration | There is no public migration or automatic recalculation path in the non-upgradeable Accountant. |

The only economically legitimate zero is therefore an effectively 100% vault
loss. In that state zero is accurate and the valuable collateral has already
been lost. Ordinary staleness, failed updates, zero local Scroll supply, and
on-chain provider failures do not naturally overwrite the stored rate with
zero.

### Downstream result of zero

For a zero-priced Veda token:

- `convertCollateralTokenToUsd()` returns zero;
- existing collateral contributes no health value;
- `borrow()` against that token reaches `BorrowAmountZero` or fails health;
- `repay()` using zero-priced liquidUSD reaches `RepaymentAmountIsZero`;
- `convertUsdToCollateralToken()` divides by zero;
- liquidation that tries to seize the zero-priced token reverts during that
  USD-to-token conversion;
- LP total-asset/share paths using the same conversion can revert.

This is mainly a denial-of-service and emergency-handling problem. It does not
let an attacker borrow liquidUSD as zero-valued debt because `borrow()` checks
that the normalized USD amount is nonzero before transferring tokens.

[`PriceProviderV2.sol`](../src/oracle/PriceProviderV2.sol) already adds:

```solidity
uint256 decodedPrice = abi.decode(data, (uint256));
if (decodedPrice == 0) revert InvalidPrice();
```

V2 does not fix the paused-rate issue because its configured selector remains
`getRate()`.

## 9. A/B/C/D classification

### Paused-but-consumed rate

| Category | Answer |
|---|---|
| A. Code defect | **Yes.** EtherFi uses Veda's raw getter for economic operations and ignores `isPaused`. |
| B. Naturally reachable protocol state | **Yes.** Correct timing/market/NAV conditions can trigger it, and all four Accountants have done so historically. |
| C. Attacker-controllable trigger | **No.** The update requires the trusted Veda updater. |
| D. Permissionless exploitation after the prerequisite | **Conditional.** Possible only with a material NAV/realizability discrepancy and an available extraction or liquidation path. Not presently demonstrated. |

**Classification:** operational/design risk with permissionless exploitation
possible after an independent naturally reachable prerequisite. It is not
directly permissionlessly exploitable from the pause logic alone.

### Zero `uint256` rate

| Category | Answer |
|---|---|
| A. Code defect | **Yes in V1.** Generic unsigned zero is not rejected. |
| B. Naturally reachable protocol state | **Only after near-total economic loss.** Ordinary failures leave the prior rate unchanged. |
| C. Attacker-controllable trigger | **No.** A trusted updater must submit zero. |
| D. Permissionless exploitation after the prerequisite | **No profitable path demonstrated.** The result is predominantly frozen conversions and liquidation/repayment DoS. |

**Classification:** trusted-updater/off-chain failure or catastrophic-loss
prerequisite; a defense-in-depth issue rather than a supported bounty exploit.

## 10. Severity and invalidation reasons

### Paused-rate issue

Best supported severity: **Low / design risk**.

Potential Medium severity requires a concrete proof of temporary freezing of
material funds or material loss after a natural pause. A stronger financial
severity requires a paused-rate divergence, active liquidity, and completed
permissionless extraction.

Likely invalidation or downgrade reasons:

1. An attacker cannot cause or choose the update.
2. A pause does not prove the stored rate is wrong.
3. Correct NAV crossing 0.5% creates no direct accounting loss.
4. All observed historical pauses predated the Cash PriceProvider.
5. Those historical pauses lasted only 11-413 seconds.
6. No post-deployment pause or loss was found.
7. Current Accountants are unpaused.
8. Current DebtManager borrow-token liquidity is zero.
9. V2 and its deployment scripts deliberately retain raw `getRate()`, which may
   be argued as an accepted integration choice.
10. Certora/Veda already treats storing an out-of-bounds rate while pausing as
    intentional Accountant behavior. The only new root cause is EtherFi's
    decision to bypass the safe getter.

### Zero-rate issue

Likely invalidation reasons:

1. No untrusted caller can submit zero.
2. No evidence shows ordinary updater or dependency failure produces zero.
3. On-chain rate providers cannot mutate the stored exchange rate.
4. Natural rounding to zero requires near-total loss.
5. A legitimate zero represents economically worthless collateral.
6. The demonstrated impact is primarily liveness/DoS, not attacker profit.
7. V2 already rejects zero.

## Recommended remediation

For Veda Accountants, configure EtherFi to call `getRateSafe()` rather than
`getRate()`, and expose the safe selector in the local interface. This causes
PriceProvider and every downstream DebtManager operation to fail closed while
the Accountant is paused.

Additionally, retain V2's nonzero check for all unsigned generic oracles. A
complete Veda adapter should validate:

```text
isPaused == false
exchangeRate != 0
lastUpdateTimestamp within an EtherFi-defined maximum age
```

Using `getRateSafe()` fixes pause handling but does not independently solve the
generic staleness issue documented in
[`SCROLL_STALE_ACCOUNTANT_PRICE_INVESTIGATION.md`](./SCROLL_STALE_ACCOUNTANT_PRICE_INVESTIGATION.md).
