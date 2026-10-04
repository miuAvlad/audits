# Stranded Frax cancellation signatures can cancel later requests and invalidate Safe recovery

## Status

**Valid candidate — Low severity.**

**In-scope impact:** griefing that significantly impedes operation of a Safe, with a
conditional argument for temporarily prolonging the unavailability of material funds
when recovery is the user's only remaining access path.

This report does not claim direct theft, permanent freezing, or permanent denial of
recovery. One stranded signature can cancel one later Frax asynchronous withdrawal and
consume one Safe nonce. Recovery signers can restore progress by signing again.

## Summary

`FraxModule.cancelAsyncWithdraw` verifies a Safe-owner quorum signature containing the
Safe's global nonce, but the signed message does not identify the withdrawal being
cancelled. It omits the pending withdrawal's recipient, amount, creation nonce, and any
monotonically increasing request ID.

Frax asynchronous withdrawal creation and cancellation also use different nonce
domains:

- `requestAsyncWithdraw` consumes `FraxModule`'s module-local per-Safe nonce; and
- `cancelAsyncWithdraw` consumes the EtherFi Safe's global nonce.

Consequently, a cancellation signature stranded by a reverted or displaced transaction
can remain valid while one Frax withdrawal is replaced by another. Any caller that has
observed the signatures can later submit them against the new withdrawal. The replay
cancels the new request and consumes the Safe's global nonce.

The strongest consequence occurs when the replay front-runs `recoverSafe`. Recovery
signatures are also bound to the Safe's global nonce. Consuming that nonce immediately
before recovery invalidates the entire recovery-signature batch and forces the recovery
quorum to coordinate and sign again. If the owner quorum is unavailable and recovery is
the user's only access path, all assets in the Safe remain inaccessible for the added
coordination period, and the normal three-day recovery delay starts only after a valid
retry is submitted.

## Severity

**Low**

The untrusted caller can:

1. cancel a later Frax asynchronous withdrawal that was not the subject of the signed
   cancellation;
2. consume the signed Safe nonce at attacker-chosen timing, provided that nonce remains
   current; and
3. invalidate a pending, not-yet-mined `recoverSafe` transaction using that nonce.

The untrusted caller cannot directly:

- transfer or steal Safe funds through the cancellation;
- cancel a recovery that has already been successfully recorded;
- postpone the recovery deadline after `recoverSafe` has succeeded;
- use old-owner signatures after the incoming owner has become effective; or
- repeat the attack indefinitely without another stranded owner-quorum signature for
  the next Safe nonce.

Under the impact taxonomy in `my-audit/inscope.md`, the best fit is the Low category:

> Griefing that results in material freezing or loss of funds or significantly impedes
> operation of the protocol.

A Medium claim for temporary freezing of material funds is conditional and weak. It
requires the owner quorum to be unavailable, material funds to be held by the Safe, and
recovery-signer coordination to take a meaningful amount of time. The contracts impose
no minimum delay before the recovery signers can sign for the new nonce.

## Affected code

### Withdrawal creation uses the module-local nonce

`requestAsyncWithdraw` verifies a single Safe-admin authorization:

- `src/modules/frax/FraxModule.sol:289-293`

Its digest calls `ModuleBase._useNonce(safe)`:

- `src/modules/frax/FraxModule.sol:359-361`
- `src/modules/ModuleBase.sol:75-81`

The signed request binds the request parameters, but incrementing this nonce does not
change `EtherFiSafe.nonce()`.

### Cancellation uses the Safe-global nonce without binding the request

`cancelAsyncWithdraw` verifies the signatures before reading the pending withdrawal:

- `src/modules/frax/FraxModule.sol:321-335`

The cancellation digest is:

```solidity
keccak256(
    abi.encodePacked(
        CANCEL_ASYNC_WITHDRAW_SIG,
        block.chainid,
        address(this),
        IEtherFiSafe(safe).useNonce(),
        safe
    )
).toEthSignedMessageHash();
```

- `src/modules/frax/FraxModule.sol:370-373`

It does not bind any of the following:

- `withdrawals[safe].amount`;
- `withdrawals[safe].recipient`;
- the matching CashModule withdrawal;
- a request creation nonce; or
- a unique request generation/ID.

If signature verification succeeds but the subsequent state check reverts with
`NoAsyncWithdrawalQueued`, EVM atomicity rolls back the preceding call to
`Safe.useNonce()`. The signatures remain observable in transaction calldata and remain
valid for that unchanged Safe nonce.

### A later request does not invalidate the cancellation

`_requestAsyncWithdraw` creates a Cash withdrawal and stores a new
`AsyncWithdrawal`:

- `src/modules/frax/FraxModule.sol:383-397`

Because this path advances only the Frax module-local nonce, a later request can be
created while the Safe-global nonce contained in an old cancellation signature remains
unchanged.

### Recovery uses the same Safe-global nonce

`recoverSafe` includes `_useNonce()` in its EIP-712 struct hash:

- `src/safe/RecoveryManager.sol:208-238`

In particular:

```solidity
bytes32 structHash = keccak256(
    abi.encode(RECOVER_SAFE_TYPEHASH, newOwner, _useNonce())
);
```

If the stale Frax cancellation consumes nonce `N` first, a recovery transaction carrying
signatures for `N` computes its digest with `N + 1` and reverts with
`InvalidRecoverySignatures`. The failed recovery transaction rolls its own nonce change
back, leaving the Safe at `N + 1` for a correctly re-signed retry.

The default recovery delay is three days:

- `src/data-provider/EtherFiDataProvider.sol:189`

The attack does not add a second three-day delay by itself. Instead, it moves the start
of the normal delay from the failed submission to the later successful retry, extending
the final recovery time by however long obtaining and submitting fresh signatures takes.

## Preconditions

1. FraxModule is an enabled module for the victim EtherFi Safe.
2. CashModule uses a nonzero withdrawal delay, allowing an asynchronous Frax request to
   remain pending.
3. The attacker obtains valid current-owner-quorum signatures for
   `cancelAsyncWithdraw` at Safe nonce `N`, but the cancellation does not successfully
   consume `N`.
4. No other successful Safe-global-nonce operation consumes `N` before the replay.
5. A different Frax asynchronous withdrawal is later pending while the Safe nonce is
   still `N`.
6. For the recovery escalation, the recovery quorum signs and submits `recoverSafe`
   using nonce `N`, and the attacker can order the stale cancellation before it.
7. For temporary unavailability of all Safe funds, the existing owner quorum is unable
   to operate the Safe and recovery is the user's only practical access path.

No malicious module, EtherFi protocol role, bridge role, Cash controller, recovery
signer, or Safe owner is required. The attacker only relays previously valid signatures
that became stranded after being publicly disclosed.

## Detailed attack path

### Phase 1: strand a generic cancellation signature

1. Victim Safe has Frax asynchronous withdrawal A pending.
2. The Safe owners sign `cancelAsyncWithdraw` at Safe nonce `N` and broadcast the
   transaction through the public mempool.
3. Withdrawal A has matured. An attacker observes the cancellation calldata and
   front-runs it with the permissionless `executeAsyncWithdraw(victimSafe)` call,
   supplying any required native bridge fee.
4. `executeAsyncWithdraw` processes A and deletes `withdrawals[victimSafe]` atomically:
   `src/modules/frax/FraxModule.sol:302-313`.
5. The original cancellation executes after A is gone. It calls `Safe.useNonce()`,
   verifies the signatures, then reverts with `NoAsyncWithdrawalQueued` at line 325.
6. The revert restores Safe nonce `N`. The owner signatures are nevertheless public in
   the cancellation transaction calldata.

The same stranded-signature condition also exists if a valid cancellation transaction
is publicly disclosed but dropped or reverts because another actor independently
removes the request first.

### Phase 2: replay against a different request

7. Later, an honest Safe admin creates asynchronous withdrawal B. Its amount and
   recipient may differ from A.
8. Creation of B advances only the Frax module-local nonce. Safe nonce remains `N`.
9. The cancellation signature from A remains valid because its digest does not identify
   A and still matches Safe nonce `N`.

### Phase 3: invalidate emergency recovery

10. The owner quorum becomes unavailable, and the recovery quorum signs
    `recoverSafe(newOwner)` using current Safe nonce `N`.
11. A relayer broadcasts the recovery transaction.
12. The attacker front-runs it by replaying A's cancellation signatures through
    `cancelAsyncWithdraw(victimSafe, signers, signatures)`.
13. FraxModule verifies the signatures against nonce `N`, cancels B, and commits the
    Safe nonce increment to `N + 1`.
14. The recovery transaction executes next. It constructs a digest using `N + 1`, so
    signatures produced for `N` fail verification.
15. The recovery quorum must obtain and submit new signatures for `N + 1`.
16. Only the successful retry records the incoming owner and starts the three-day
    recovery delay. Until completion, a user without a functioning owner quorum cannot
    access any assets held by the Safe.

## Why the attacker cannot obtain a higher standalone impact

### Cancellation does not transfer funds

`cancelAsyncWithdraw` cancels the CashModule request and deletes Frax request metadata.
The assets remain in the Safe. It does not approve, transfer, bridge, or otherwise move
the victim's tokens to the attacker.

### Processing and bridging are atomic

`executeAsyncWithdraw` calls `cashModule.processWithdrawal`, bridges the withdrawn
FraxUSD, and deletes local state in one transaction. Without a separate vulnerability or
privileged configuration change, there is no ordinary interval in which the replay can
delete the Frax request after CashModule transferred assets but before Frax bridges them.

### A recorded recovery is independent of later nonce changes

Once `recoverSafe` succeeds, it stores the incoming owner and timestamp. A subsequent
Frax cancellation may consume another nonce, but it does not delete the incoming owner,
change the timestamp, or restart the recovery delay.

### The replay is one-shot

The successful replay advances the Safe nonce. The same signatures no longer verify.
Permanent denial requires a new valid owner-quorum signature for every subsequent Safe
nonce, which this vulnerability does not provide.

## Proof-of-concept outline

A Foundry test can demonstrate the issue with the following assertions:

1. Create Frax request A and record `safe.nonce() == N`.
2. Sign the generic Frax cancellation digest for `N`.
3. Execute A before submitting the cancellation.
4. Submit the cancellation and expect `NoAsyncWithdrawalQueued`.
5. Assert `safe.nonce() == N` after the revert.
6. Create request B with different amount and recipient.
7. Assert the Frax module nonce advanced while `safe.nonce() == N`.
8. Produce recovery signatures over `RecoverSafe(newOwner, N)`.
9. Replay the old Frax cancellation and assert:

   - request B is deleted; and
   - `safe.nonce() == N + 1`.
10. Submit the recovery transaction and expect `InvalidRecoverySignatures`.
11. Re-sign for `N + 1`, submit successfully, and assert that the recorded recovery
    timestamp is based on the later retry.

## Recommendation

Bind cancellation authorization to a unique request generation. For example, maintain a
monotonically increasing `asyncWithdrawalId[safe]`, store it with every request, load the
request before consuming the Safe nonce, and sign:

```solidity
AsyncWithdrawal memory withdrawal = withdrawals[safe];
uint256 safeNonce = IEtherFiSafe(safe).useNonce();

keccak256(
    abi.encode(
        CANCEL_ASYNC_WITHDRAW_SIG,
        block.chainid,
        address(this),
        safeNonce,
        safe,
        withdrawal.id,
        withdrawal.amount,
        withdrawal.recipient,
        deadline
    )
).toEthSignedMessageHash();
```

Before consuming the Safe nonce, load the pending withdrawal and use its stored ID and
parameters to construct the digest. Reject expired signatures with an absolute signed
deadline.

Using only amount and recipient is weaker than a request ID because two distinct
requests may intentionally use identical values. A monotonic request generation
unambiguously binds consent to one state instance.

As an architectural alternative, creation and cancellation can share the same nonce
domain, so creating any replacement request automatically invalidates cancellation
signatures associated with the previous state.

## Reasons for invalidation or downgrade

### Invalidate the wrong-request replay if cancellation is intentionally perpetual and generic

If the documented signing semantics explicitly authorize cancelling whichever Frax
asynchronous withdrawal is pending now or at any future time while the Safe nonce remains
unchanged, applying the signature to B is intended rather than unauthorized. The
documentation must clearly communicate that the signature is a transferable bearer
authorization unrelated to a particular request.

### Invalidate if no persistent Frax request can exist in deployed scope

If every in-scope production deployment permanently enforces a zero Cash withdrawal
delay, `_requestAsyncWithdraw` executes immediately and does not leave the persistent
request required by this attack.

### Invalidate the public replay path if signatures cannot become observable while live

If cancellation signatures are guaranteed to be delivered only through a private,
atomic execution channel that never exposes calldata for failed or displaced
transactions, an arbitrary observer cannot acquire the stranded signature. A frontend
policy or ordinary private-relay preference reduces likelihood but is not an on-chain
guarantee.

### Downgrade if recovery signatures can be regenerated immediately

There is no on-chain cooldown before recovery signers can sign for `N + 1`. If the
recovery quorum can always regenerate and privately submit signatures immediately, the
added unavailability may be only a few blocks and may not satisfy the program's
"significantly impedes operation" requirement.

### Do not escalate using an unauthorized pending recovery

A hypothetical path in which nonce consumption defeats a last-minute
`cancelRecovery`, allowing an attacker-selected incoming owner to take control, requires
the recovery quorum to have already authorized that attacker or requires a separate
recovery vulnerability. That prerequisite dominates the impact and is outside this
finding's standalone threat model.

### Potential overlap with the generic no-expiry observation

`SIGNATURE_SECURITY_FINDINGS.md` already records that module-local signatures generally
lack deadlines and explicit cancellation. This report's narrower root cause is not just
absence of expiry: the Frax cancellation omits request identity while request creation
and cancellation deliberately use independent nonce domains. Nevertheless, a judge who
groups all stranded-current-nonce authorizations under the generic no-expiry root cause
may treat this report as a duplicate or variant rather than a new issue.
