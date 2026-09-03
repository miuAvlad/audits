# CashModule whitelist removal desynchronizes pending Stargate withdrawals

## Status

**Valid — High severity, conditional on an authorized module de-whitelisting action.**

> **Final bounty assessment: outside the applicable trust and security assumptions.**
> The technical impact can be High after the prerequisite transition, but that
> transition requires the trusted Cash controller to de-whitelist/decommission the
> module without first resolving its pending requests. Under the assumed operational
> model, the protocol is expected to perform this migration safely. The repository and
> reviewed on-chain history do not establish that this unsafe transition occurred in
> production. This document therefore records a lifecycle/design hazard, not an
> unprivileged High-severity bounty finding under those assumptions.

The untrusted attacker cannot remove StargateModule from the Cash withdrawal-module
whitelist. However, the Cash controller does not need to be malicious: removing or
replacing a module is a supported operational action, and the implementation allows
removal without resolving requests that were created while the module was trusted.
Once that normal lifecycle transition occurs, any external caller can exploit the stale
request.

## Summary

CashModule decides whether a pending withdrawal is module-owned by checking whether its
stored recipient is a member of the **current**
`whitelistedModulesCanRequestWithdraw` set. It does not persist the request's
authorization provenance when the request is created.

StargateModule creates a Cash withdrawal whose recipient is StargateModule itself.
While StargateModule remains in the current whitelist, only StargateModule can process
that request. If the Cash controller removes StargateModule before the pending request
is completed, the exact same request is reclassified as an ordinary permissionless
withdrawal.

After the delay, any caller can invoke `CashModule.processWithdrawal(victimSafe)`.
CashModule transfers the Safe's tokens to StargateModule, deletes the Cash withdrawal,
and accepts the transaction when the Safe remains healthy. The attacker's transaction
does not execute StargateModule's bridge logic.

StargateModule subsequently refuses to bridge because its `executeBridge` function
requires the matching Cash withdrawal to still exist. Cancelling the Stargate request
deletes only StargateModule's metadata and does not return tokens already transferred
to the module. StargateModule has no token rescue or arbitrary transfer function, so
the transferred assets remain stranded.

## Severity

**High**

The affected amount can be the full amount of an owner-authorized bridge request. The
attacker needs no signature, Safe role, module role, or capital other than transaction
gas. The impact is permanent freezing rather than attacker profit.

The severity is conditional on a Cash controller first removing StargateModule from the
withdrawal-module whitelist while at least one Stargate request is pending. If the
applicable bounty rules categorically exclude findings that become exploitable only
after a privileged configuration transition, the program may downgrade or reject it.
Technically, the role is not required to behave maliciously or exceed its intended
authority; routine module deprecation is sufficient.

## Affected code

### Request provenance is inferred from mutable configuration

`CashModuleSetters.requestWithdrawalByModule` verifies that the caller is currently
allowed and stores the module only as the withdrawal recipient:

- `src/modules/cash/CashModuleSetters.sol:193-210`

`CashModuleSetters.configureModulesCanRequestWithdraw` allows the Cash controller to
remove a module without checking or resolving pending requests:

- `src/modules/cash/CashModuleSetters.sol:215-231`

The repository tests explicitly establish removal as supported behavior, including
removal after the module has already been removed from EtherFiDataProvider:

- `test/safe/modules/cash/Withdrawals.t.sol:756-778`

### Processing authorization uses current membership

`CashModuleStorageContract._processWithdrawal` applies the module-only caller check
only when the stored recipient remains in the current whitelist:

- `src/modules/cash/CashModuleStorageContract.sol:298-310`

The relevant logic is equivalent to:

```solidity
if ($.whitelistedModulesCanRequestWithdraw.contains(
    $$.pendingWithdrawalRequest.recipient
)) {
    if (msg.sender != $$.pendingWithdrawalRequest.recipient) {
        revert OnlyModuleThatRequestedCanWithdraw();
    }
}
```

After removal, the outer condition is false and no caller authentication remains.

`processWithdrawal` is externally callable. Its `onlyEtherFiSafe(safe)` modifier
validates that the supplied `safe` address is a registered EtherFi Safe; it does not
validate `msg.sender`:

- `src/modules/cash/CashModuleCore.sol:277-279`
- `src/modules/ModuleBase.sol:108-112`

### Transfer and deletion are committed atomically

CashModule instructs the Safe to transfer the requested ERC20 amount to the stored
recipient, emits the event, deletes the pending request, and then checks health:

- `src/modules/cash/CashModuleStorageContract.sol:312-332`

CashModule is the caller seen by `EtherFiSafe.execTransactionFromModule`. The Safe
accepts enabled/default modules and executes the token transfer:

- `src/safe/EtherFiSafeCore.sol:173-200`
- `src/safe/ModuleManager.sol:191-196`

The hook expressly skips its own health check when the executing module is CashModule.
CashModule performs `debtManager.ensureHealth(safe)` after deleting the request:

- `src/hook/EtherFiHook.sol:49-54`
- `src/modules/cash/CashModuleStorageContract.sol:330-332`

An unhealthy Safe or failed token transfer reverts the entire transaction. A healthy
debit-mode Safe holding a standard ERC20 such as USDC completes the transfer and
deletion.

### Stargate requires the deleted Cash state

StargateModule stores its own bridge request after requesting the Cash withdrawal:

- `src/modules/stargate/StargateModule.sol:208-230`

Before moving funds cross-chain, `executeBridge` requires a matching Cash request and
then asks CashModule to process it:

- `src/modules/stargate/StargateModule.sol:236-252`

After the attack, the matching Cash request has been deleted, so `executeBridge`
reverts with `CannotFindMatchingWithdrawalForSafe` before it reaches the bridge.

`cancelBridge` calls `cancelWithdrawalByModule` only if the matching Cash request
still identifies StargateModule. When the Cash request is already gone, it deletes only
StargateModule's local request:

- `src/modules/stargate/StargateModule.sol:259-275`

Neither StargateModule nor its base contracts expose a rescue, sweep, arbitrary token
transfer, or owner withdrawal function.

## Preconditions

1. A registered EtherFi Safe holds a supported standard ERC20 and remains healthy after
   the requested withdrawal.
2. Safe owners authorize `StargateModule.requestBridge` for a nonzero amount.
3. CashModule has a nonzero withdrawal delay, so a pending request exists.
4. StargateModule is allowed both by EtherFiDataProvider and by
   `whitelistedModulesCanRequestWithdraw` when the request is created.
5. The Cash controller later removes StargateModule from
   `whitelistedModulesCanRequestWithdraw` before the request is processed.
6. The attacker calls `processWithdrawal` after the request's `finalizeTime` and
   before a benign caller invokes `StargateModule.executeBridge`.

The mainnet configuration includes StargateModule in
`cashModule.modulesCanRequestWithdraw`, demonstrating that this integration is an
intended production flow:

- `deployments/mainnet/10/config.json:106-112`

## Detailed attack path

1. The victim Safe owns `100_000e6` USDC and has sufficient excess collateral or no
   debt, so withdrawing that amount leaves it healthy.
2. Safe owners sign a Stargate bridge authorization for:
   - `safe = victimSafe`
   - `asset = USDC`
   - `amount = 100_000e6`
   - the intended destination EID and recipient
   - the current Safe nonce.
3. Any relayer submits `StargateModule.requestBridge`.
4. StargateModule verifies the signatures and consumes the Safe nonce.
5. StargateModule calls
   `CashModule.requestWithdrawalByModule(victimSafe, USDC, 100_000e6)`.
6. CashModule confirms StargateModule is currently authorized and stores:
   - `recipient = StargateModule`
   - `tokens[0] = USDC`
   - `amounts[0] = 100_000e6`
   - `finalizeTime = T`.
7. StargateModule separately stores the matching `CrossChainWithdrawal`.
8. Before removal, an unrelated caller invoking
   `CashModule.processWithdrawal(victimSafe)` at or after `T` reverts with
   `OnlyModuleThatRequestedCanWithdraw`.
9. During ordinary module deprecation or replacement, the Cash controller calls
   `configureModulesCanRequestWithdraw([StargateModule], [false])`.
10. The pending request remains unchanged, but current membership now returns false.
11. At `T`, the attacker front-runs the intended bridge executor and calls
    `CashModule.processWithdrawal(victimSafe)`.
12. `_processWithdrawal` skips `OnlyModuleThatRequestedCanWithdraw` because the
    recipient is no longer currently whitelisted.
13. CashModule calls the victim Safe as an enabled/default Safe module.
14. The Safe transfers `100_000e6` USDC to StargateModule.
15. CashModule deletes the pending withdrawal and the final health check succeeds.
16. A later `StargateModule.executeBridge(victimSafe)` reads an empty Cash request and
    reverts with `CannotFindMatchingWithdrawalForSafe`.
17. If the owners call `cancelBridge`, StargateModule deletes its local request but
    does not return the USDC.
18. The USDC remains held by StargateModule with no production recovery path.

## Why common invalidation arguments do not defeat the finding

### “A trusted role must act maliciously”

No malicious role behavior is necessary. The controller performs the exact supported
operation of removing a withdrawal module. The vulnerability is that authorization for
already-created requests changes retroactively when that operation occurs.

The finding should nevertheless disclose this privileged lifecycle prerequisite because
some bounty policies exclude all configuration-conditioned issues.

### “The attacker cannot steal the funds”

The impact is permanent freezing, not direct attacker profit. The untrusted caller
irreversibly separates CashModule state from StargateModule state and moves assets from
a user-controlled Safe into a contract without a recovery function.

### “The owner can cancel”

Before the attack, owner cancellation can avoid the loss. After processing, the Cash
request is gone. `cancelBridge` only deletes Stargate metadata and does not transfer
tokens back.

### “Re-whitelisting StargateModule restores the request”

Re-whitelisting changes only current membership. It does not recreate the deleted Cash
withdrawal. `executeBridge` continues to fail its matching-request check.

Creating a new matching withdrawal is not a recovery: processing that request transfers
another equal amount from the Safe before bridging one amount, leaving the original
stranded balance in StargateModule.

### “Health checks or token failures prevent exploitation”

Those checks make the transaction atomic but do not prevent exploitation against a
healthy Safe and a normal ERC20. If transfer or health validation fails, all state rolls
back; otherwise transfer and deletion commit together.

## Root cause

The request's authorization class is not immutable.

CashModule overloads the recipient address as both:

1. the destination of the token transfer; and
2. an indirect indication that the request was created by a privileged module.

It recomputes the second property from a mutable global whitelist during processing and
cancellation. Removing a module therefore changes the authorization semantics of
already-pending requests.

## Recommended remediation

Persist request provenance when the request is created. For example, store:

```solidity
struct WithdrawalRequest {
    address[] tokens;
    uint256[] amounts;
    address recipient;
    uint96 finalizeTime;
    address requester;
    bool requestedByModule;
}
```

For a module-created request:

- set `requester = msg.sender`;
- set `requestedByModule = true`;
- require `msg.sender == requester` during processing regardless of current whitelist
  membership; and
- use the stored provenance for cancellation and module callbacks.

The current whitelist should determine whether a module may create **new** requests. It
must not retroactively determine who may process existing requests.

As defense in depth:

1. add a controlled unwind path that returns tokens already held by bridge modules to
   the originating Safe;
2. define an explicit module-deprecation sequence that stops new requests but preserves
   processing/cancellation authority for old requests;
3. test removal before, at, and after `finalizeTime`; and
4. add an invariant that a request created by a module can never be processed by a
   different caller, regardless of later whitelist changes.

## Suggested regression test

A Foundry regression test should:

1. deploy the production CashModule, Safe, hook, DebtManager, and StargateModule setup;
2. fund a healthy Safe with standard mock USDC;
3. create a signed Stargate request with a nonzero Cash withdrawal delay;
4. prove an attacker cannot process it while StargateModule is whitelisted;
5. remove StargateModule using the Cash controller role;
6. warp to the exact `finalizeTime`;
7. process from an unrelated address;
8. assert the Safe balance decreased and StargateModule balance increased by the full
   amount;
9. assert the Cash request was deleted;
10. assert `executeBridge` reverts with
    `CannotFindMatchingWithdrawalForSafe`;
11. cancel the Stargate request with valid owner signatures; and
12. assert the tokens remain in StargateModule and no recovery entry point exists.

## Validation notes

The production call path and lack of a recovery surface were independently verified
against the repository. No matching issue was found by searching the repository's audit,
signature, or Certora known-issue material.

No OpenKritt scan or audit harness was run for this report. The supplied claim of a
passing PoC was not rerun in this workspace.
