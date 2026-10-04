# [M] Provider ownership transfers preserve delegated updaters, allowing former owners to retain quote control

## Summary

`PriceProviderFactory`, `PriceProviderFactoryL2`, and `AnchoredProviderFactory` maintain provider ownership separately from delegated updater permissions. When provider ownership is transferred, the factories update `providerOwner` and the creator-indexed provider sets, but do not invalidate any existing entries in `isUpdater`.

Consequently, a former owner can authorize itself or another address as an updater before transferring ownership. That stale delegate remains authorized indefinitely and can continue changing `confidenceParam` after the new owner has taken control. In the non-anchored providers, this parameter directly shapes executable bid and ask prices used by every live pool connected to the provider.

The end-to-end PoC uses fresh, unchanged oracle observations and real `MetricOmmPool` instances. Before the stale update, the authenticated uncertainty bands make the tested cycle unprofitable. After the former owner sets `confidenceParam` to zero, the same 100-token route returns approximately `103.78677` tokens after bin traversal and pool fees, realizing a 378-bps loss against LP inventory.

## Affected code

The vulnerable authorization pattern appears in:

- `smart-contracts-poc/contracts/PriceProviderFactory.sol`
- `smart-contracts-poc/contracts/PriceProviderFactoryL2.sol`
- `smart-contracts-poc/contracts/AnchoredProviderFactory.sol`

The direct bad-price impact applies most strongly to `PriceProvider` and `PriceProviderL2`. `AnchoredPriceProvider` retains the same stale authorization bug, but its reference-band clamp prevents the delegate from tightening quotes through the configured anchor band; there the practical impact is generally limited to widening quotes or temporarily halting swaps.

## Root cause

Updater permissions are provider-scoped and independent of ownership:

```solidity
mapping(address provider => address) public providerOwner;
mapping(address provider => mapping(address updater => bool)) public isUpdater;

function _requireUpdater(address provider) internal view {
    if (msg.sender != providerOwner[provider] && !isUpdater[provider][msg.sender])
        revert NotProviderUpdater();
}
```

The owner may grant any address updater authority:

```solidity
function grantUpdater(address provider, address updater)
    external
    onlyProviderOwner(provider)
{
    require(_providers.contains(provider), ProviderNotTracked());
    isUpdater[provider][updater] = true;
    emit UpdaterGranted(provider, updater);
}
```

Ownership transfer does not clear or version those permissions:

```solidity
function transferProviderOwnership(address provider, address newOwner)
    external
    onlyProviderOwner(provider)
{
    require(_providers.contains(provider), ProviderNotTracked());
    require(newOwner != address(0));
    address previousOwner = providerOwner[provider];

    providerOwner[provider] = newOwner;
    _providersByCreator[previousOwner].remove(provider);
    _providersByCreator[newOwner].add(provider);

    emit ProviderOwnershipTransferred(provider, previousOwner, newOwner);
}
```

The stale delegate therefore continues to pass `_requireUpdater()` and can reach the provider setter:

```solidity
function setConfidence(address[] calldata providers, uint256[] calldata values) external {
    for (uint256 i; i < providers.length; ++i) {
        require(_providers.contains(providers[i]), ProviderNotTracked());
        _requireUpdater(providers[i]);
        PriceProvider(providers[i]).setConfidenceParam(values[i]);
    }
}
```

This conflicts with the repository's ownership-transfer tests. `PriceProviderFactory.t.sol::testOldOwnerCannotUpdateAfterTransfer` expects the previous owner to lose update authority, while the anchored-factory test explicitly describes the post-transfer property as "old owner lost control." Those tests only cover the former owner's implicit owner privilege and omit the case where it first grants itself explicit updater permission.

## Attack path

Consider providers already used by funded pools and configured with conservative confidence values:

1. The current provider owner has an operational updater or grants itself updater permission.
2. Provider ownership is transferred to a new curator, multisig, or replacement key.
3. `providerOwner` now reports the new owner, but all previously authorized updater addresses remain valid.
4. After the confidence cooldown, the stale updater sets `confidenceParam = 0`, which is within the enforced bounds.
5. The update removes the oracle uncertainty component and leaves only the immutable margin adjustment in the executable quote.
6. In the same transaction, or before the new owner can react, the attacker trades against the narrowed pool quote and hedges through another Metric pool or an external venue.
7. The attacker keeps the price difference while the affected LPs receive the opposite side of the adverse trades.

The attack does not require a stale, delayed, forged, or incorrect oracle observation. The PoC keeps both observations unchanged and fresh throughout the transition.

## Economic example

The PoC uses two correct observations whose authenticated 500-bps uncertainty bands overlap:

```text
low feed:  mid = 100, spread = 500 bps, interval = [95, 105]
high feed: mid = 104, spread = 500 bps, interval = [98.8, 109.2]
```

With the full bands preserved, a low-pool to high-pool cycle cannot meet a break-even minimum output and reverts.

The former owner then uses its stale updater permission to set both providers' confidence to zero. The real Metric router path produces:

```text
cycle input:                  100.000000000000000000
cycle output:                 103.786769561849080908
profit after pool fees:       378 bps
```

This is not merely a view-level quote discrepancy. The PoC settles both swaps through real pools, crosses their bin state, pays the configured protocol/admin rake, and verifies the attacker's increased token balance.

Although the PoC models two providers transferred during one operational handover, one affected provider is sufficient when the attacker can hedge at an external market price lying inside the authentic uncertainty band.

## Impact and severity

The stale updater retains economically meaningful control after ownership has ostensibly moved to another party. It can:

- narrow quotes and expose LP inventory to adverse selection;
- widen quotes and make normal swaps uneconomic;
- produce `FeedStalled` for configurations where the selected confidence makes `bid >= ask` or a boundary output is reached;
- repeat updates after each one-minute cooldown until every stale updater is identified and revoked.

The demonstrated 3.78% realized LP loss exceeds the contest's Medium threshold and also exceeds its percentage threshold for High. Medium is nevertheless the defensible classification because exploitation requires a provider ownership transition, a previously delegated updater, suitable market/feed divergence, and available pool liquidity.

## Why recovery does not prevent the first loss

The new owner can revoke an updater only if it knows every authorized address. Updaters are stored in a nested mapping rather than an enumerable set, so there is no on-chain method to obtain the complete authorization list. Historical events can be indexed off-chain, but they do not provide an atomic handover guarantee.

Moreover, revocation is reactive. A stale updater contract can call `setConfidence` and execute the arbitrage in one transaction. Even after the address is identified and revoked, the malicious confidence value remains active, and `CONFIDENCE_COOLDOWN` prevents the new owner from restoring it for one minute. A provider can also serve multiple pools whose admins are different from the provider owner, making coordinated emergency pausing unreliable.

## Scope and trust assumptions

This issue does not require malicious behavior from:

- the current provider owner;
- the PriceProvider factory's trusted `ADMIN_ROLE`;
- the Oracle `ADMIN_ROLE`;
- a pool admin;
- the off-chain oracle or its publisher.

The actor is authorized before the transfer but should cease to have control after the ownership security boundary changes. The vulnerability is the factory continuing to honor that old authorization.

The finding is also independent of the separate confidence-unit scaling issue. Under the current implementation, the PoC uses `1_000_000` as the conservative pre-transfer value because it preserves the raw 500-bps spread. If the unit denominator were corrected, the same authorization exploit would use the intended conservative setting before transfer and a smaller valid value afterward. Unauthorized post-transfer quote control remains the root cause.

## Proof of concept

Factory-level authorization and quote proof:

```bash
cd smart-contracts-poc
forge test --match-path test/PriceProviderOwnershipStaleUpdater.audit.t.sol -vv
```

End-to-end real-pool proof:

```bash
cd metric-periphery
FOUNDRY_ALLOW_PATHS='["../smart-contracts-poc"]' \
FOUNDRY_AUTO_DETECT_REMAPPINGS=false \
FOUNDRY_OFFLINE=true \
forge test \
  -R smart-contracts-poc/=../smart-contracts-poc/ \
  --match-path test/ProviderOwnershipStaleUpdaterPoolPoC.t.sol \
  -vv
```

PoC files:

- `smart-contracts-poc/test/PriceProviderOwnershipStaleUpdater.audit.t.sol`
- `metric-periphery/test/ProviderOwnershipStaleUpdaterPoolPoC.t.sol`

Results:

```text
PriceProviderOwnershipStaleUpdaterAuditTest: 1 passed
ProviderOwnershipStaleUpdaterPoolPoC:         2 passed
real-pool profit after fees:                  378 bps
```

## Defensibility assessment

### Strong points

- The stale authorization is deterministic and appears identically in all three provider factories.
- The repository explicitly tests that an old owner loses control after transfer, but fails to cover pre-existing updater permissions.
- The attack uses bounded parameter values and does not bypass the confidence setter or cooldown.
- The oracle observations are correct, fresh, unchanged, and inside overlapping authenticated uncertainty bands.
- The end-to-end PoC demonstrates realized token profit against real pool liquidity after fees and bin traversal.
- The new owner cannot atomically enumerate and invalidate all old delegates during handover.

### Main invalidation risk

The protocol may argue that updater permissions are deliberately attached to the provider rather than its owner and are expected to survive ownership changes, for example so operational updater bots remain active when a governance multisig rotates.

That interpretation is possible because no NatSpec explicitly states that ownership transfer clears delegates. It is weakened by three facts:

1. the tests state that the former owner loses control;
2. the handover has no acceptance step or delegate-list acknowledgement by the new owner;
3. the new owner cannot atomically inspect and approve the inherited updater set on-chain.

There is also a trust-model argument: judges may characterize the former provider owner as a previously trusted curator and treat a malicious handover as an off-chain trust failure. The strongest response is that a role transfer exists specifically to end the former party's authority; the exploit occurs only after on-chain ownership reports that control has moved, and it can be performed by any inherited delegate rather than the current trusted owner.

Overall, the implementation bug is high-confidence, while contest acceptance as a Medium is moderately defensible. It is submission-worthy, but weaker than a fully permissionless finding because its validity depends on judges recognizing ownership transfer as revoking inherited operational authority.

## Recommendation

Invalidate every existing updater in O(1) when ownership changes by versioning updater permissions:

```solidity
mapping(address provider => uint256 epoch) public updaterEpoch;
mapping(address provider => mapping(address updater => uint256 epoch)) private updaterAuthorization;

function _isUpdater(address provider, address updater) internal view returns (bool) {
    return updaterAuthorization[provider][updater] == updaterEpoch[provider];
}
```

Initialize each provider at a non-zero epoch, record the current epoch when granting an updater, and increment `updaterEpoch[provider]` during ownership transfer. The new owner can then explicitly re-grant any operational updater it wants to retain.

Also consider a two-step ownership transfer requiring acceptance by `newOwner`. This prevents arbitrary addresses from forcing providers into another curator's `_providersByCreator` list, but it must be combined with updater invalidation to close the stale-authority path.

Add tests proving that:

- every updater granted before transfer fails afterward;
- a former owner that explicitly granted itself updater permission cannot call `setConfidence` after transfer;
- the new owner can re-grant intended delegates;
- the behavior is consistent across L1, L2, and anchored factories.
