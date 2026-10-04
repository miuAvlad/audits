# Signature Security Review

## Scope

This document reviews signature authorization paths in `projects/etherfi_cash-v3`, with emphasis on:

- replay protection and nonce management;
- domain separation (`chainId`, Safe address, and verifying contract);
- deadlines and signature revocation;
- whether all execution-critical parameters are bound to the signature; and
- mutable protocol configuration used after a signature has been accepted.

The review is source-based. It does not assert that every issue is present in every deployed proxy: deployed implementation addresses, initialization values, role assignments, and operational controls must be checked separately.

### Severity summary

| ID | Assessment | Finding |
| --- | --- | --- |
| SIG-01 | Invalid — owner-authorized unsafe configuration | A zero recovery threshold permits signatureless recovery after owners authorize that threshold |
| SIG-02 | Invalid — trusted privileged target configuration | Delayed Stargate and Wormhole requests do not bind the external bridge target/configuration |
| SIG-03 | Conditional / design-dependent | Cross-chain asset-recovery authorization has neither an amount cap nor an expiry |
| SIG-04 | Low / hardening | Module-local authorizations generally have no deadline or explicit nonce cancellation |
| SIG-05 | Conditional on migration overlap | CashModule signatures do not bind the verifying CashModule contract |
| SIG-06 | Conditional on trusted-admin threat model | Immediate EtherFi Liquid and Midas operations do not bind mutable external protocol targets |
| SIG-07 | Integration risk — production signer unverified | RecoveryManager uses noncanonical EIP-712 type hashes that standard typed-data encoders will not reproduce |
| SIG-08 | Conditional on off-chain threat model | Enso and Across signatures bind opaque execution payloads without enforcing that they match the displayed high-level order |
| SIG-09 | Design-dependent | Safe recovery preserves independently configured administrators and their module-signing authority |

## I-01 — Zero recovery threshold permits signatureless recovery

**Assessment:** Invalid — owner-authorized unsafe configuration
**Confidence:** High
**Affected code:** `src/safe/RecoveryManager.sol:129-142`, `src/safe/RecoveryManager.sol:208-239`

### Description

`setRecoveryThreshold()` accepts `threshold == 0`. Its only range check applies when the threshold is greater than two:

```solidity
if (threshold > 2 && threshold - 2 > $.userRecoverySigners.length())
    revert RecoverySignersLengthLessThanThreshold();
```

After the owners authorize a threshold of zero, `recoverSafe()` can be called with empty signer and signature arrays:

- `len < recoveryThreshold` evaluates as `0 < 0`, which is false;
- the signature loop is skipped; and
- `validSignatures != recoveryThreshold` evaluates as `0 != 0`, which is false.

The call therefore creates a recovery request for an attacker-selected nonzero `newOwner` without a recovery signature.

### Important prerequisite

This is not an unauthenticated takeover from the default state. A valid owner quorum must first sign `setRecoveryThreshold(0, ...)`, or an equivalent privileged/upgrade path must write zero. The bug is that an owner-authorized configuration silently disables the signature requirement while recovery remains enabled.

### Impact

Once the threshold is zero and recovery is enabled, any account can initiate recovery to itself. After the recovery delay, the pending owner can take control unless the legitimate owners cancel in time. An attacker can also repeatedly submit recovery requests, consuming the Safe nonce and replacing/restarting the pending recovery state.

### Attack flow

1. The Safe owners sign and submit a threshold update to zero, intentionally or due to a UI/configuration error.
2. An attacker calls `recoverSafe(attacker, [], [])`.
3. The function accepts zero valid signatures and schedules the attacker as incoming owner.
4. The attacker completes ownership transfer after the configured delay if the request is not cancelled.

### Recommendation

Reject zero explicitly:

```solidity
if (threshold == 0) revert InvalidThreshold();
```

Also enforce the invariant during initialization and upgrades, and add tests proving that threshold zero always reverts.

### Reasons for invalidation or downgrade

Invalidate this finding only if at least one of the following is true for the actual deployed implementation:

- `setRecoveryThreshold(0, ...)` is rejected by code not present in the reviewed source;
- recovery can never be enabled while the stored threshold is zero and that invariant is enforced on-chain; or
- the deployed implementation differs and `recoverSafe()` requires at least one valid signature independently of the threshold.

The finding may be downgraded if owner-authorized unsafe configurations are explicitly considered out of scope. A frontend preventing zero is a mitigation, not an invalidation, because the contract remains callable directly.

## I-02 — Delayed bridge signatures omit mutable bridge targets

**Assessment:** Invalid — trusted privileged target configuration
**Confidence:** High
**Affected code:** `src/modules/stargate/StargateModule.sol:179-184`, `:208-252`, `:304-319`, `:489-505`; `src/modules/wormhole/WormholeModule.sol:165-170`, `:193-245`, `:281-283`, `:293-306`, `:359-372`

### Description

The Stargate request signature binds:

```text
method, chainId, module, Safe nonce, Safe,
destination EID, asset, amount, recipient, maximum slippage
```

It does not bind `AssetConfig.isOFT` or `AssetConfig.pool`. The delayed `executeBridge()` path reads the current configuration when `_bridge()` runs, rather than preserving the configuration that existed when owners signed and queued the request.

The Wormhole request similarly binds the destination EID, asset, amount, and recipient, but not the configured NTT manager or dust-decimal configuration. The request uses the then-current dust configuration to queue an amount, while execution later loads the current NTT manager.

Both configurations can be changed by their respective module-admin roles while a signed withdrawal is pending. `executeBridge(safe)` only verifies that the supplied address is a registered EtherFi Safe; it does not restrict `msg.sender`, so execution after the delay is permissionless by design.

### Impact

Owners can sign one bridge route but have execution occur through a different externally configured contract. A compromised or malicious module admin can wait for a legitimate pending request, replace the target, and trigger execution. The module receives the withdrawn tokens, approves the newly configured target, and calls it.

For Stargate, `_setAssetConfigs()` asks the configured pool for `token()` and compares it with the asset. This blocks an accidental mismatched legitimate pool, but a malicious contract can return the expected token and still misuse the subsequent approval/call. Wormhole only checks that the NTT manager is nonzero.

### Attack flow

1. Owners sign and queue a legitimate delayed bridge.
2. Before execution, the relevant module admin changes the pool/NTT-manager configuration.
3. The withdrawal delay expires.
4. The attacker or any relayer calls `executeBridge(safe)`.
5. The signed asset and amount are withdrawn to the module and passed to the unsigned, newly configured target.

### Recommendation

Bind the target and all execution-relevant configuration to the signed digest and store a snapshot in the pending request. Execution should use that snapshot. Alternatively, increment a configuration version and bind that version to the signature, rejecting execution when the version changed. Configuration updates can also automatically cancel affected pending requests.

### Reasons for invalidation or downgrade

Invalidate this finding if deployed code proves that:

- target configuration is immutable after initialization;
- changing configuration atomically invalidates every affected pending request; or
- execution uses a stored/signed target snapshot rather than the current mapping.

The finding may be downgraded or treated as accepted trust if the Stargate/Wormhole module-admin roles are explicitly trusted to move arbitrary Safe funds and their compromise is out of scope. A timelock or multisig on those roles reduces likelihood but does not bind the owners' signed intent.

## SIG-03 — Cross-chain recovery signature has no amount cap or deadline

**Assessment:** Conditional / design-dependent
**Confidence:** High
**Affected code:** `src/modules/recovery/AssetRecoveryModule.sol:42-60`, `:105-127`; `src/top-up/AssetRecoveryDispatcher.sol:79`; `src/top-up/TopUpV2.sol:35-45`

### Description

The source-chain recovery digest binds:

```text
chainId, module, per-Safe nonce, Safe, token, recipient,
Safe salt, destination EID, hash(LayerZero options)
```

It binds neither an amount nor an absolute deadline. On the destination chain, `TopUpV2.executeRecovery()` transfers the entire current balance of the token to the signed recipient.

The signed source transaction can be withheld before submission. In addition, cross-chain delivery can be delayed or retried. Because destination execution reverts when the balance is zero, a failed packet may remain retryable and succeed after tokens later arrive, depending on LayerZero retry semantics and configuration.

The same repository's `SafeAssetRecoveryModule` explicitly binds a deadline to prevent a stashed signature from remaining valid (`src/modules/recovery/SafeAssetRecoveryModule.sol:123-142`). The cross-chain variant lacks that protection.

### Impact

A signature intended to recover a known balance can be executed much later and sweep additional tokens that arrived after signing. The destination transfer remains limited to the signed token and recipient, but the economic quantity is unbounded by the authorization.

### Attack flow

1. Owners sign recovery while the destination TopUp has balance `X`.
2. A holder/relayer delays submitting or delivering the authorization.
3. More of the same token reaches the TopUp, increasing its balance to `X + Y`.
4. Recovery executes and transfers `X + Y` to the signed recipient.

### Recommendation

Add a signed absolute `deadline` and a signed `maxAmount` (or exact amount) to both the source digest and cross-chain payload. At destination, reject expired messages and transfer no more than the authorized amount. If full-balance recovery is intentional, a deadline should still be included.

### Reasons for invalidation or downgrade

Invalidate the amount component if full-balance sweep semantics are explicitly intended and owners are clearly signing authorization over all present and future balance of that token. Invalidate the delay component only if an on-chain, immutable expiry is enforced elsewhere for both pre-submission signatures and already-sent messages.

The finding can be downgraded if the destination account is guaranteed never to receive additional funds after authorization. A trusted relayer policy is only an operational mitigation unless the contract cryptographically/enforceably limits who can submit and when.

## SIG-04 — Module-local signatures lack expiry and explicit cancellation

**Assessment:** Low / hardening
**Confidence:** High
**Affected code:** `src/modules/ModuleBase.sol:64-81` and signature entry points in Aave V3, EtherFi Stake/Liquid, Frax, Midas, beHYPE, and CashModule setters

### Description

Most module authorization hashes correctly include the chain ID, module address, Safe address, operation parameters, and a per-Safe nonce. However, they generally omit an absolute deadline. `ModuleBase` exposes `getNonce()` and internally increments the nonce through `_useNonce()`, but provides no dedicated user-facing function to cancel/invalidate the current nonce.

As a result, an unused signature for the current nonce remains executable indefinitely while:

- its signer is still a Safe admin/owner as required by that entry point;
- the module remains enabled/whitelisted; and
- no other action has consumed that module's current nonce.

The EtherFi Liquid `secondsToDeadline` field does not expire the authorization. It is a relative duration used to construct an external withdrawal deadline from execution time, so delaying submission shifts the effective external deadline forward.

### Impact

A leaked, withheld, or forgotten current-nonce authorization can execute after market conditions or owner intent have changed. Signed minimum-output constraints limit some price risk but do not provide revocation or time-bounded consent.

### Recommendation

Include an absolute signed deadline in every user authorization and reject `block.timestamp > deadline`. Add an authorized nonce-invalidation function, ideally allowing the Safe/admin to advance a module nonce to a specified greater value. Document whether nonces are global to a module or shared across operations.

### Reasons for invalidation or downgrade

Invalidate this finding if perpetual bearer-style authorizations are an explicit protocol requirement and users are clearly informed that signatures do not expire. It is also invalid for any specific entry point that already binds and enforces an absolute deadline or has an effective on-chain cancellation path.

The risk is mitigated, but not fully invalidated, when another module action naturally consumes the same nonce, the signer is removed as admin, or the module is disabled. Only the signature matching the current nonce is live; older signatures are already invalidated by nonce advancement.

## SIG-05 — CashModule signatures omit the verifying contract

**Assessment:** Conditional on migration overlap
**Confidence:** Medium
**Affected code:** `src/libraries/CashVerificationLib.sol:49-50`, `:96`, `:110`, `:125`; callers in `src/modules/cash/CashModuleSetters.sol`

### Description

CashModule's EIP-191 digests bind the method identifier, `block.chainid`, Safe, nonce, and operation parameters, but do not include `address(this)` or another CashModule identifier. Therefore, the signed payload is not domain-separated between two CashModule instances on the same chain.

This differs from most other modules in the repository, which include `address(this)` in their digest.

### Impact

If two compatible CashModule instances are simultaneously callable for the same Safe and their relevant nonce values align, a signature produced for one instance can be submitted to the other. A Safe-wide nonce prevents executing the same withdrawal signature twice, but does not necessarily prevent a relayer from choosing the unintended module as the first execution target. `setMode`, spending-limit, and cashback-setting paths use module-local nonce state and are also sensitive to aligned instances.

The practical impact depends heavily on deployment and migration architecture.

### Recommendation

Include the verifying CashModule proxy address in every digest:

```text
method, chainId, address(this), Safe, nonce, parameters
```

Because these library calls execute as internal code in the module context, `address(this)` should resolve to the CashModule proxy used by the caller.

### Reasons for invalidation or downgrade

Invalidate this finding if protocol invariants guarantee that only one compatible CashModule can ever be enabled or callable for a Safe on a chain, including during upgrades and migrations. It is also invalid if each instance has a cryptographically distinct method/domain constant not visible in the reviewed library or if nonce namespaces can never align.

An operational promise to avoid overlapping old/new modules reduces exploitability but is weaker than contract-level domain separation. If migration overlap is possible, the finding remains valid even though direct double execution is prevented by a shared Safe nonce.

## SIG-06 — Immediate operations use unsigned mutable external targets

**Assessment:** Conditional on trusted-admin threat model
**Confidence:** Medium
**Affected code:** `src/modules/etherfi/EtherFiLiquidModule.sol:181-245`, `:281-330`, `:530-574`; corresponding `EtherFiLiquidModuleWithReferrer`; `src/modules/midas/MidasModule.sol:109-180`, `:202-250`, `:261-305`

### Description

EtherFi Liquid signatures bind the user-facing assets, amounts, minimum return, and withdrawal parameters, but not the Teller/withdrawal-queue addresses loaded from mutable mappings. Midas signatures similarly bind asset, Midas token, amount, and output constraints, but not the deposit/redemption vault addresses loaded from `vaults[midasToken]`.

Unlike SIG-02, these operations execute immediately in the same transaction that verifies the signature. There is no on-chain pending interval, but a configuration administrator can change the target after a user signs and before a relayer submits the signed transaction.

### Impact

A valid signature can authorize calls and token approvals to an external protocol address different from the one the signer expected. Minimum-return and balance-delta checks can cause malicious behavior to revert, but they do not protect cases where a replacement target can satisfy the minimum output while extracting value through unfavorable but still permitted terms, or where an async flow moves tokens before later settlement.

### Recommendation

Bind the selected Teller, queue, deposit vault, and redemption vault—or a versioned hash of the relevant configuration—to the signature. Reject execution if the live configuration no longer matches. Frontends should display the resolved target and configuration version before signing.

### Reasons for invalidation or downgrade

Invalidate this finding if the external target mappings are immutable in deployed code, or if the digest already commits to an immutable value that uniquely determines and verifies the target. It may be treated as accepted trust if the configuration roles are explicitly authorized to redirect user assets and their compromise/front-running is out of scope.

Because request and execution are atomic, this finding should be downgraded relative to delayed-execution target substitution unless an administrator or compromised role can observe signed payloads before they are submitted. Strong minimum-return checks also reduce, but do not universally eliminate, impact.

## SIG-07 — RecoveryManager uses noncanonical EIP-712 type hashes

**Assessment:** Integration risk — production signer unverified
**Confidence:** High
**Affected code:** `src/safe/EtherFiSafeBase.sol:65-98`; consumers in `src/safe/RecoveryManager.sol:104-180` and `:208-274`

### Description

Five RecoveryManager type-hash constants were generated from type strings containing spaces after commas. EIP-712's canonical `encodeType` representation does not include those spaces. Consequently, a standard `eth_signTypedData_v4` implementation derives a different type hash and digest from the constants expected on-chain.

| Operation | On-chain type hash | Canonical EIP-712 type hash |
| --- | --- | --- |
| `SetUserRecoverySigners(address[] recoverySigners,bool[] shouldAdd,uint256 nonce)` | `0x13a92003fda0d03ec95bfceee0b09375118fa2f6b07643738d22bb5ab1624892` | `0x2389b928b2d26a9a50eef3bdcc60b0b91fb3876f7913e5c89be026f783b31eb8` |
| `ToggleRecoveryEnabled(bool shouldEnable,uint256 nonce)` | `0x5c10794d3a4aa2f8b255fb0edd6a1590ef803ef6938cd05b4b429373f6d7f23a` | `0x9225b5dbcfd88590a1b1e51f608fbc91336a17f5cb1b75285f9f206fff9225f0` |
| `RecoverSafe(address newOwner,uint256 nonce)` | `0x2992e7b46f73f4592f11ad26ecd28369c2c2c21ff82538e3a580b30a75cf7475` | `0x5f445acbd575e8d177cd7d230a56872ff9b6aa315b266aea7176b99594b183f4` |
| `OverrideRecoverySigners(address[2] recoverySigners,uint256 nonce)` | `0x04bcf772e9794a9d599eb843d9bc5d71ec13708fac13593aefc4ff9cfc4ba9e7` | `0x5c37bcff80b6c2d25769e84d866d08813daf2d7a7aa72491d1ca8b1fcee42869` |
| `SetRecoveryThreshold(uint8 threshold,uint256 nonce)` | `0x55fbacc2ae7fb06b8e6207b13a0239f651c6c83bbee4bf809286d76d9ee9a8ac` | `0xa34e948c61079b4a3b810c2a18e719b839bfe104fe1f6ec4bbff40e8cefae371` |

`CancelRecovery(uint256 nonce)` is unaffected because its type contains only one field and therefore no comma or inserted space. Existing Solidity tests manually use the contract constants and sign the resulting digest, so they reproduce the contract's nonstandard encoding instead of exercising a normal wallet encoder.

### Impact

Signatures generated by standards-compliant EIP-712 wallets and typed-data libraries are rejected on-chain. This can break recovery configuration and recovery itself at the time users need it. Exploitation does not require a malicious trusted role; this is primarily a recovery availability and integration failure.

### Recommendation

Replace the constants with hashes of the canonical no-space type strings. Add an integration test that creates typed data through a standard wallet/library encoder rather than constructing the final digest from the on-chain constant. Consider whether pending signatures produced by the legacy custom signer require a temporary compatibility path during migration.

### Reasons for invalidation or downgrade

Invalidate the practical wallet-compatibility impact if the production signer deliberately signs the exact nonstandard digest, standard EIP-712 wallet/library support is explicitly not required, and that custom path is tested end to end. Even under that assumption, the constants remain noncanonical and create integration risk.

Downgrade if affected operations are always generated and submitted by a controlled signer that cannot invoke a canonical typed-data encoder. This does not require a trusted role to become malicious and should not be dismissed merely because the Solidity unit tests pass.

## SIG-08 — Opaque execution payloads are not checked against the signed high-level swap order

**Assessment:** Conditional on off-chain threat model
**Confidence:** Medium
**Affected code:** `src/enso/EnsoSwapModule.sol:19-65`, `:192-230`, `:278-326`, `:405-442`; `src/across/AcrossSwapModule.sol:19-90`, `:238-430`, `:509-567`

### Description

The Enso and Across authorization hashes commit to the complete opaque route calldata or destination message. A relayer therefore cannot alter that payload after signature creation. However, the contracts do not fully decode the payload and enforce that its behavior matches the human-readable fields in the signed `Order`.

For Enso cross-chain swaps, `dstToken`, `recipient`, and `minAmountOut` describe the intended result, while the signed `swapData` determines the actual route and destination behavior. The module does not verify the destination output against those fields on-chain.

For Across classic routes, the deposit recipient is the multicall handler and the destination message determines the final transfer behavior. For origin-swap routes, calldata is forwarded to the configured periphery. The high-level destination fields are not sufficient on-chain constraints on those opaque instructions.

Thus, a compromised quote API, route builder, frontend, or signing backend could pair benign displayed order fields with malicious execution bytes before the user signs. The payload cannot later be changed, but the signature authorizes bytes whose semantics may not match what the user was shown.

### Impact

If users rely on the high-level order for consent and cannot independently inspect the opaque route, the signed source amount may be routed to an unintended token, recipient, or destination action. No malicious EtherFi on-chain administrator is required, but exploitation requires compromise or malicious behavior in the off-chain quote/signing-presentation path before signature creation.

### Recommendation

Decode and validate every route field that can be checked on the origin chain. In particular, validate final/fallback recipients, destination token and minimum output from Across instructions where the message format permits it. Prefer route-specific typed structures over unrestricted opaque calldata. If arbitrary calldata must remain authoritative, clearly present that fact and independently decode the exact payload in the client before signing.

### Reasons for invalidation or downgrade

Invalidate this finding if the protocol explicitly defines the opaque execution payload—not the high-level `Order`—as the canonical user authorization, and the wallet independently decodes and accurately displays its full effects before signing. It may also be invalid under a threat model that fully trusts the quote builder, frontend, and signing backend to construct the payload correctly.

Downgrade when destination contracts independently enforce the same recipient, token, and minimum-output constraints or when only non-value-moving metadata can differ. The fact that raw calldata is hashed prevents post-signature relayer tampering, but does not by itself invalidate a pre-signature semantic mismatch.

## SIG-09 — Recovery preserves non-owner Safe administrators

**Assessment:** Design-dependent
**Confidence:** High
**Affected code:** `src/safe/EtherFiSafeCore.sol:100-149`, `src/safe/MultiSig.sol:322-352`, recovery flow in `src/safe/RecoveryManager.sol`, and module entry points protected by `ModuleBase.onlySafeAdmin`

### Description

When recovery replaces compromised owners, it does not revoke independently configured Safe administrators. The recovery logic deliberately distinguishes owners from other administrators and preserves an administrator for which `_isOwner(admin)` is false. Those addresses therefore remain accepted by `isAdmin()` and can continue signing module-local operations after ownership recovery.

This matters because some module actions require only one current Safe administrator. For example, Frax asynchronous withdrawal authorization permits a signed recipient. A compromised non-owner administrator that survives recovery can continue authorizing a withdrawal to an attacker-controlled recipient. The recovered owner may be able to cancel the delayed request or revoke the administrator, but security depends on winning that operational race.

### Impact

If recovery is intended to restore a user's account after all relevant signing authority may have been compromised, the recovered account is not fully isolated from surviving non-owner administrators. A compromised administrator can retain value-moving authority after the owner set changes.

No EtherFi protocol or bridge administrator must become malicious. The required actor is an independently configured Safe administrator whose key is compromised or malicious before recovery.

### Recommendation

Define whether account recovery is owner-only replacement or complete authority rotation. For complete recovery, revoke all existing administrators, or include the post-recovery administrator set in the recovery authorization. As a defense-in-depth alternative, freeze administrator-authorized modules until the new owner explicitly confirms or replaces the administrators.

### Reasons for invalidation or downgrade

Invalidate this finding if recovery is explicitly documented as replacing owners only and preserving independent administrators is an intended, clearly communicated invariant. It is also invalid if surviving administrators cannot authorize any value-moving or security-sensitive operation; the reviewed module permissions do not appear to satisfy that condition.

Downgrade if every administrator-authorized value movement has a sufficiently long, reliable cancellation period and recovery atomically alerts or equips the new owner to revoke surviving administrators before execution. A cancellation race is a mitigation, not a complete invalidation.

## Signature properties that appear sound

- Safe owner and recovery-management operations use EIP-712 domain separation that binds the chain and Safe contract.
- Reviewed signature paths generally include a nonce, preventing straightforward repeated execution in the same nonce domain.
- Owner quorum verification rejects duplicate signer addresses.
- Enso signs the router/module, order data, full calldata, Safe, chain, nonce, and deadline.
- Across binds order/deposit data, message/swap calldata, and execution targets.
- OpenOcean binds full calldata and validates decoded input token, amount, and recipient.

## Verification status

The findings above were established by manual source tracing and type-hash recomputation. `forge build` completed successfully. A focused run of `test/safe/Recovery.t.sol` compiled but could not enter the test cases because the repository setup requires the `TEST_CHAIN` environment variable. No protocol source code was modified as part of the review.

