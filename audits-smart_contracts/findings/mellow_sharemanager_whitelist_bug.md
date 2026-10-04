# Mellow Flexible Vaults — ShareManager Finding (Draft)

> **Author:** Vlad  
> **Project:** Mellow Flexible Vaults  
> **Scope:** `flexible-vaults/src/managers/ShareManager.sol`  
> **Commit:** `eca8836`  
> **Status:** Draft

---

## Finding — `TokenizedShareManager::_update` whitelist logic is inverted (DoS + ACL bypass)

### Summary
`TokenizedShareManager::_update` reverts when **both** `from` and `to` are whitelisted and `hasTransferWhitelist` is enabled, due to a missing negation in the transfer whitelist check.  
Additionally, the current condition can allow accounts that are **not intended to transfer** to move funds (ACL bypass), depending on the surrounding call paths and how `AccountInfo.canTransfer` is used.

### Location
- `2025-07-mellow-flexible-vaults-miuAvlad/flexible-vaults/src/managers/ShareManager.sol`
  - **Line ~139** (commit `eca8836`)

### Root Cause
When the transfer whitelist feature is active, the code currently checks:

```solidity
if (flags_.hasTransferWhitelist()) {
    if (info.canTransfer || !$.accounts[to].canTransfer) {
        revert TransferNotAllowed(from, to);
    }
}
```

`info` is `$.accounts[from]`.

- The intention is to revert when **either** the sender or receiver is **not** whitelisted for transfers.
- But the condition uses `info.canTransfer` instead of `!info.canTransfer`.

As a result:
- If `from` is whitelisted (`info.canTransfer == true`), the condition becomes true and **reverts**, even when `to` is also whitelisted.
- If `from` is **not** whitelisted (`info.canTransfer == false`) and `to` is whitelisted, then the condition becomes false and **does not revert**, enabling an unauthorized sender to transfer.

### Preconditions

#### Internal Preconditions
- `flags_.hasTransferWhitelist() == true`
- `from != address(0)` and `to != address(0)`
- `$.accounts[from].canTransfer == true` (for the DoS case)
- (Implicit) `_update(from, to)` is reached from an entry point (e.g., `transfer`)

#### External Preconditions
- Transfer whitelist feature is enabled (flag set)
- Sender/receiver `AccountInfo` configured with `canTransfer` values

### Attack / Failure Path

#### DoS for whitelisted users
1. Both `A` and `B` are configured with `canTransfer == true`.
2. `hasTransferWhitelist` is enabled.
3. `A` calls:
   ```solidity
   tokenizedShareManager.transfer(B, amount);
   ```
4. Flow:
   `transfer → _transfer(A, B, amount) → _update(A, B)`
5. Inside `_update`, the condition `info.canTransfer` is true, causing:
   `revert TransferNotAllowed(A, B)`.

#### ACL bypass (unauthorized sender can transfer)
If `A` is configured with `canTransfer == false` and `B` is `true`:
- `info.canTransfer` is false, `!accounts[to].canTransfer` is false, so the condition is false → **no revert**, allowing transfers from a non-whitelisted sender.

### Impact
- **Denial of Service (DoS) for whitelisted users:** legitimate transfers revert when whitelist mode is enabled.
- **ACL bypass:** senders that should be blocked can transfer under certain configurations.
- Overall, the transfer whitelist mechanism becomes unreliable and may break intended compliance/permissioning.

### Proof of Concept (PoC)

> Note: You can also adapt the PoC to demonstrate the ACL bypass by removing the `expectRevert` and setting `canTransfer` for the sender to `false`.

```solidity
function testCreate() external {
    Deployment memory deployment = createVault(vaultAdmin, vaultProxyAdmin, assetsDefault);

    MockTokenizedShareManager shareManager = MockTokenizedShareManager(address(deployment.shareManager));
    vm.startPrank(vaultAdmin);

    // Setting hasTransferWhitelist flag to true
    shareManager.setFlags(IShareManager.Flags({
        hasMintPause: false,
        hasBurnPause: false,
        hasTransferPause: false,
        hasWhitelist: false,
        hasTransferWhitelist: true, 
        globalLockup: globalLockup,
        targetedLockup: targetedLockup
    }));

    // Setting accounts canTransfer flag to true
    shareManager.setAccountInfo(address(10), IShareManager.AccountInfo({
        canDeposit: true,
        canTransfer: true,
        isBlacklisted: false,
        lockedUntil: 1
    }));
    shareManager.setAccountInfo(address(11), IShareManager.AccountInfo({
        canDeposit: true,
        canTransfer: true,
        isBlacklisted: false,
        lockedUntil: 1
    }));
    vm.stopPrank();

    // Mint tokens to user 1 
    shareManager.mintShares(address(10), 1 ether);

    // Transfer tokens from user A to user B
    vm.startPrank(address(10));
    vm.expectRevert(
        abi.encodeWithSelector(IShareManager.TransferNotAllowed.selector, address(10), address(11))
    );
    shareManager.transfer(address(11), 0.5 ether);
    vm.stopPrank();
}
```

### Mitigation
Fix the whitelist condition by negating the sender check:

```diff
- if (info.canTransfer || !accounts[to].canTransfer) {
+ if (!info.canTransfer || !accounts[to].canTransfer) {
      revert TransferNotAllowed(from, to);
  }
```

Optional hardening:
- Add explicit comments defining whitelist semantics (“`canTransfer == true` means whitelisted for transfer when `hasTransferWhitelist` is on”).
- Add tests for:
  - whitelisted→whitelisted transfer succeeds
  - non-whitelisted→whitelisted transfer reverts
  - whitelisted→non-whitelisted transfer reverts
  - non-whitelisted→non-whitelisted transfer reverts

