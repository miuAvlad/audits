# A zero-balance collateral flag lets an unavailable oracle freeze withdrawals of unrelated Aave assets

## Status

**Conditional Medium candidate.**

The underlying cross-reserve lock is reproduced against the repository's real Aave v4 test instance. The scoped impact is met only if the relevant oracle or reserve remains unavailable for at least ten days. The stale collateral flag itself has no expiry, but the current proof does not establish that a production oracle interruption will necessarily last ten days.

The program's temporary-freezing requirement excludes cases with a user-side workaround. Neither repayment nor the existing administrative cleanup is a user-side path for recovering the supplied funds. Nevertheless, oracle recovery or prompt privileged cleanup can shorten the actual freeze and is the principal submission risk.

## Summary

`LendGateway.supply` always enables the supplied Aave reserve as collateral. A subsequent full withdrawal reduces the Safe's supplied shares to zero, but Aave v4 does not clear the reserve's collateral-status bit.

When Aave later calculates the Safe's account data, it iterates every reserve whose status bit says that it is collateral or debt. It reads each reserve's oracle price before checking whether the Safe has any supplied shares in that reserve. Consequently, a stale or reverting price source for a previously exited reserve makes complete-account validation revert even though that reserve contributes no value to the position.

The failure contaminates unrelated assets. With zero units of stale asset A and material supplied balance in healthy asset B, withdrawing B refreshes the complete account, reads A's unavailable oracle, and reverts atomically. EtherFi's withdrawal and lend-opt-out flows both use this Aave withdrawal path, while the opt-out loop skips A itself because `suppliedOf(safe, A) == 0`. Safe owners have no entry point that clears the residual collateral flag.

If the unavailable-price condition lasts at least ten days, material funds in B are inaccessible for the required period without a user-side workaround.

## Affected code

- `src/modules/lend-gateway/LendGateway.sol:329-338`
  - `supply` supplies the asset and unconditionally calls `spoke.setUsingAsCollateral(reserveId, true, safe)`.
- `src/modules/lend-gateway/LendGateway.sol:358-367`
  - `withdraw` forwards the Aave withdrawal but does not clear collateral usage after a full exit.
- `lib/aave-v4/src/spoke/Spoke.sol:244-270`
  - `withdraw` subtracts all supplied shares and refreshes account data, but leaves the collateral-status bit enabled when the resulting share balance is zero.
- `lib/aave-v4/src/spoke/Spoke.sol:711-750`
  - `_processUserAccountData` reads `getReservePrice(reserveId)` before checking `suppliedShares > 0`.
- `src/modules/cash/CashLendLib.sol:334-355`
  - `sourceWithdrawal` pulls a withdrawal shortfall from Aave through `gateway.withdraw`; the stale zero-balance reserve therefore blocks requests for another token.
- `src/modules/cash/CashLendLib.sol:570-593`
  - `_unwindLendCollateral` only visits assets whose current supplied balance is nonzero. It cannot detect or clean a zero-balance collateral flag.
- `src/modules/lend-gateway/LendGateway.sol:440-449`
  - A cleanup method exists, but it is restricted to the CashModule or an authorized gateway driver and is not exposed to Safe owners.

## Root cause

The integration treats a zero supplied balance as a complete exit, while the upstream Aave position has two independent pieces of state:

1. the Safe's supplied shares for the reserve; and
2. the Safe's `usingAsCollateral` status bit.

EtherFi checks and unwinds only the first. Aave retains the second after a full withdrawal and subsequently uses it to decide which reserves participate in account-wide processing. That processing fetches the oracle price before filtering out a zero supplied balance.

The result is an orphaned, economically empty status bit with a live dependency on the old reserve's oracle.

## State transition

```text
Initial
  A balance = 0
  A collateral flag = false

Supply A through LendGateway
  A balance > 0
  A collateral flag = true

Fully withdraw A while its feed is healthy
  A balance = 0
  A collateral flag = true       <- orphaned flag

A oracle becomes stale or reverts
  A balance = 0
  A collateral flag = true
  complete-account refresh = revert

Supply healthy B
  B balance > 0
  B collateral flag = true

Attempt to withdraw B
  B shares are tentatively removed
  account refresh reads A's oracle
  oracle reverts
  entire transaction rolls back
  B remains supplied
```

## Failure path

1. An EtherFi Safe is migrated to the LendGateway engine.
2. An authorized EtherFi flow supplies asset A through `LendGateway.supply`.
3. The Safe later performs an authorized full withdrawal of A while A's price source is healthy.
4. Aave sets A's supplied shares to zero but leaves A enabled as collateral.
5. A's oracle subsequently becomes stale or begins reverting. Alternatively, A's reserve is paused while its unusable status bit remains attached to the Safe.
6. The Safe holds or later supplies material value in unrelated healthy asset B.
7. The user requests a withdrawal of B. `CashLendLib.sourceWithdrawal` calls `LendGateway.withdraw` to pull B out of Aave.
8. Aave's withdrawal refreshes the complete account because B is collateral.
9. Account processing encounters the orphaned A status and calls A's price source before testing A's zero supplied balance.
10. The price call reverts, rolling back B's withdrawal.
11. Repeating the withdrawal, requesting lend opt-out, or attempting to withdraw another collateral reserve reaches the same poisoned account refresh.
12. If the unavailable-price state persists for at least ten days, B meets the scoped temporary-freezing duration.

No EtherFi trusted role must be malicious. The precursor full withdrawal is a normal authorized user action, and the final trigger is failure or pause of an external oracle/reserve. This absence of an attacker-controlled oracle outage is also a material likelihood and acceptance risk.

## Impact

An economically empty historical reserve can make material balances in every other collateral reserve inaccessible. The direct impact is broader than the expected unavailability of A: healthy B is frozen solely because A's zero-balance status was not cleaned.

Affected operations include:

- withdrawal requests that need to source tokens from Aave;
- direct gateway withdrawals by authorized modules;
- complete lend opt-out, because withdrawing any nonzero reserve encounters the poisoned account refresh;
- new borrows and other operations that validate complete account health; and
- liquidation while account valuation itself cannot complete.

Repayment is not an exit for the frozen collateral. Aave repayment does not refresh complete account data, so repayment from loose debt tokens can remain possible, but it neither clears A's collateral flag nor moves B out of Aave. If repayment must first withdraw supplied tokens, it encounters the same revert.

## Ten-day scope requirement

The ghost flag persists indefinitely on-chain. Time passing does not clear it, and the user cannot clear it through CashModule. Therefore a test can warp more than ten days while the source continues reverting and show that B remains locked.

That alone does not prove a production feed will be unavailable for ten days. A defensible Medium submission should establish at least one of the following:

1. a deployed supported reserve whose oracle or rate source can remain paused until a governance action, with no automatic recovery deadline;
2. a historical interruption of at least ten days in a deployed source;
3. a paused Aave reserve that prevents collateral disablement and remains paused for at least ten days; or
4. another attacker-controlled condition that keeps complete-account processing unavailable for the required duration.

If every realistic feed recovery or reserve pause is shorter than ten days, the demonstrated lock falls below the program's scoped threshold even though the code defect exists.

## User-side workarounds

There is no clear user-side workaround:

- Safe owners cannot call `LendGateway.setUsingAsCollateral` because it is `onlyDriver`.
- `processLendOptOut` retries withdrawals of nonzero balances but skips the zero-balance ghost and remains blocked by the poisoned refresh.
- Repayment can reduce debt but does not release B or clear A.
- The Aave position is internal accounting; the user does not hold a transferable receipt token that can be moved around the failing withdrawal path.
- Sending additional tokens to the Safe does not remove the stale status dependency.

## Privileged and external recovery

For one stale ghost whose Aave reserve and gateway are not paused, EtherFi can recover the account:

1. the operating Safe holding `LEND_GATEWAY_ADMIN_ROLE` calls `setDriver(cleanupAddress, true)`;
2. the cleanup driver calls `setUsingAsCollateral(victimSafe, A, false)`; and
3. the user retries the withdrawal of B.

This is a privileged protocol rescue, not a user-side alternate path. It does, however, make permanent-freeze and High-severity claims inappropriate.

The recovery has additional limitations:

- `setUsingAsCollateral` is gated by `whenNotPaused` on LendGateway.
- Aave's `_validateSetUsingAsCollateral` requires the affected reserve not to be paused even when collateral is being disabled.
- With multiple stale ghost flags, clearing one can still encounter another unavailable oracle during the post-clear account refresh, reverting the transaction and restoring the first flag.
- Restoring or replacing the price source may require Aave or oracle governance rather than the EtherFi gateway administrator.

## Proof of concept

The focused reproduction is:

```text
test/safe/modules/cash/lend/GhostCollateralOracleLock.t.sol
test_zeroBalanceStaleReserveBlocksWithdrawalOfAnotherAsset
```

It uses the repository's real Aave v4 test deployment and demonstrates that:

1. a full weETH withdrawal leaves `suppliedOf == 0` while the collateral flag remains true;
2. the old weETH source is made to revert with `StalePrice()`;
3. supplying USDC still succeeds;
4. withdrawing USDC reverts on the old weETH source;
5. USDC remains supplied after the reverted withdrawal; and
6. a gateway driver clearing the weETH collateral flag restores the USDC exit.

Command:

```bash
FOUNDRY_PROFILE=lend TEST_CHAIN=10 forge test \
  --match-path test/safe/modules/cash/lend/GhostCollateralOracleLock.t.sol -vv
```

The PoC currently proves the cross-reserve lock and privileged remediation. It does not independently prove a ten-day production outage.

## Severity

Suggested severity: **Medium, conditional**.

The scope includes temporary freezing of material funds, but requires at least ten days without a user-side workaround. The contract state has no user cleanup or expiry and can remain poisoned longer than ten days. The unresolved requirement is demonstrating a realistic unavailable-price or paused-reserve condition lasting that long.

This should not be submitted as High or as permanent freezing because a fresh oracle read or privileged cleanup can restore access without loss of principal.

## Rejection and invalidation risks

1. **The outage duration is not attacker-controlled.** The strongest objection is that the PoC assumes the old oracle continues reverting. A production source may recover before ten days.
2. **Privileged cleanup exists.** Reviewers may treat `setDriver` plus `setUsingAsCollateral(false)` as an adequate operational remedy, even though it is not user-side and the impact definition specifically focuses on user-side workarounds.
3. **Normal feeds generally recover.** Short Chainlink heartbeat interruptions or ordinary market closures are unlikely by themselves to satisfy ten days.
4. **The precursor is user-authorized.** A normal full withdrawal creates the ghost; an untrusted caller cannot generally create arbitrary victim state without an already authorized module flow.
5. **The root behavior is in Aave v4.** Reviewers may classify the price-before-zero-balance behavior as an upstream issue. The EtherFi-specific response is that LendGateway creates the residual status, does not clear it after full withdrawal, and gives owners no cleanup route while using Aave as custody for their funds.
6. **Repayment may remain available.** This limits debt escalation and liquidation claims but does not make the supplied collateral accessible.
7. **A paused reserve already freezes that reserve.** The incremental impact must be framed as freezing unrelated healthy B, not the expected inability to withdraw paused A.

## Recommendations

1. After every gateway withdrawal, query the remaining supplied balance. If it is zero, atomically call `spoke.setUsingAsCollateral(reserveId, false, safe)` while the oracle is still healthy.
2. During migration and lend opt-out, inspect Aave collateral-status bits as well as supplied balances and clear every zero-balance flag before finalizing.
3. Add a Safe-owner-authorized cleanup operation for disabling a zero-balance reserve as collateral. It should not permit enabling collateral or changing a nonzero risk position without the normal authorization checks.
4. Add an emergency batch cleanup capable of clearing multiple zero-balance flags atomically or without refreshing account data between each flag.
5. Upstream, avoid fetching an oracle price for a reserve with zero supplied shares and zero debt, or have Aave automatically clear collateral status after a full withdrawal.
6. Add regression tests covering full exit, subsequent oracle staleness/pause, unrelated collateral withdrawal, lend opt-out, multiple ghost flags, and a duration exceeding ten days.
