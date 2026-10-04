# Solid Findings Wrap-up

This document summarizes the three strongest findings currently worth carrying forward into report drafting.

Severity labels are provisional and should be rechecked against final contest severity rules and sponsor assumptions.

## H01 - Vested rewards over zero or dust share supply can zero-mint deposits or let dust holders capture new depositor value

**Severity:** High candidate  
**Status:** PoC added  
**Main impact:** direct user loss / value capture by dust-share holder / deposit DoS on safe routes  
**Affected components:** `dreUSDs`, `dreRewardsDistributor`, ERC4626 share accounting

**Affected code / lines:**
- `dreusd/contracts/dreUSDs.sol:109-113` - `totalAssets()` includes `rewardsDistributor.vestedAmount()` in the ERC4626 asset base.
- `dreusd/contracts/dreUSDs.sol:204-207` - `_claimVestedRewards()` pulls vested rewards from the distributor.
- `dreusd/contracts/dreUSDs.sol:213-216` - `_deposit()` adds claimed rewards and the user's assets to `_virtualBalance`, then mints the precomputed share amount.
- `dreusd/contracts/dreUSDs.sol:222-231` - `_withdraw()` lets temporary capital exit before meaningful rewards have vested.
- `dreusd/contracts/dreRewardsDistributor.sol:108-139` - `addRewards()` schedules new rewards over the 7-day vesting window.
- `dreusd/contracts/dreRewardsDistributor.sol:155-179` - `vestedAmount()` / `_computeVestedAmount()` make rewards enter `totalAssets()` linearly over time.
- `dreusd/lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol:216-225` - `deposit()` computes `shares = previewDeposit(assets)` before calling `_deposit()`.
- `dreusd/lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol:270-271` - `_convertToShares()` uses `(totalSupply() + 10 ** _decimalsOffset()) / (totalAssets() + 1)`.
- `dreusd/lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol:324-326` - `_decimalsOffset()` defaults to `0`, so the virtual share offset is only `1`.

### Summary

`dreUSDs.totalAssets()` includes vested rewards from `dreRewardsDistributor`, while ERC4626 deposit shares are minted from the ratio between `totalSupply()` and `totalAssets()`. If `totalSupply()` is reduced to dust before scheduled rewards vest, the later vested rewards can make `totalAssets()` large relative to the remaining share supply.

A user can temporarily provide meaningful capital so the vault appears normally staked when rewards are scheduled, then redeem before those rewards vest and leave only dust shares behind. Once the rewards vest, that dust supply owns almost the entire vault. A later depositor is then priced against a large `totalAssets()` and a tiny `totalSupply()`, causing their deposit to mint zero or severely underpriced shares. Their deposited dreUSD is added to `_virtualBalance`, so it is accounted as vault assets and cannot be recovered through the excess-token path.

This has two important variants: the zero-supply / first-depositor case can mint exactly zero shares and strand the first deposit, while the dust-supply case can arise after temporary liquidity exits and can let the remaining dust holder capture later depositor value.

### Root Cause

`dreUSDs.totalAssets()` returns:

```solidity
_virtualBalance + rewardsDistributor.vestedAmount()
```

Rewards increase the ERC4626 asset base as they vest, but they do not mint additional shares. OpenZeppelin ERC4626 computes deposit shares before `dreUSDs._deposit()` runs:

```text
sharesOut = assetsIn * (totalSupply + 10 ** _decimalsOffset()) / (totalAssets + 1)
```

`dreUSDs` does not override `_decimalsOffset()`, so the virtual share offset is `1`:

```text
sharesOut = assetsIn * (totalSupply + 1) / (totalAssets + 1)
```

When `totalSupply` is dust and `totalAssets` is dominated by newly vested rewards, `sharesOut` can round to zero or become severely smaller than the ownership that the new deposit should receive. The existing dust holder is diluted too little and can redeem a disproportionate amount of the victim-funded vault.

### Detailed Flow

```text
precondition:
  -> dreUSDs.rewardsDistributor is configured
  -> rewards are generated from global/offchain reserve revenue, not necessarily from current dreUSDs TVL
  -> there is no onchain minimum share supply / reward-to-staked-assets ratio guard
```

```text
temporary capital setup:
  -> attacker deposits meaningful capital into dreUSDs
      -> IERC4626(dreUSDs).deposit(largeAmount, attacker)
          -> totalSupply becomes meaningful
          -> _virtualBalance increases by largeAmount
  -> the vault now appears to have enough staked assets for reward scheduling
```

```text
reward scheduling:
  -> keeper calls dreUSDManager.mintRewards(FiatMint m, custodianSig)
      -> dreUSDManager.dreRewardsDistributor()
          -> reads IdreUSDs(dreUSDs).rewardsDistributor()
      -> dreUSDManager._mintFromFiatUsd(m, custodianSig)
          -> validates custodian signature
          -> checks mintRef replay / validUntil / chainId / daily cap
          -> IdreUSD(dreUSD).mint(m.receiver, dreUSDAmount)
              - receiver is the rewards distributor
      -> IdreRewardsDistributor(dreRewardsDistributor()).addRewards()
          -> IdreUSDs(vault).claimVestedRewards()
          -> newRewards = dreUSD.balanceOf(distributor) - rewards
          -> rewards = newRewards
          -> cTs = block.timestamp
          -> eTs = block.timestamp + 7 days
```

```text
attacker exits before rewards vest:
  -> immediately after addRewards(), vestedAmount() is 0 or very small
  -> attacker calls IERC4626(dreUSDs).redeem(attackerShares - dust, attacker, attacker)
      -> ERC4626.previewRedeem() uses totalAssets before meaningful rewards have vested
      -> dreUSDs._withdraw()
          -> _claimVestedRewards() claims 0 or negligible rewards
          -> _virtualBalance -= withdrawnAssets
          -> burns the redeemed shares
          -> returns the attacker's capital
  -> attacker keeps only dust shares
```

```text
reward accrual over dust supply:
  -> time passes during the 7-day linear vesting window
  -> dreRewardsDistributor.vestedAmount()
      -> _computeVestedAmount()
          -> vested = (min(block.timestamp, eTs) - cTs) * rewards / (eTs - cTs)
  -> dreUSDs.totalAssets()
      -> _virtualBalance + rewardsDistributor.vestedAmount()
      -> becomes large while totalSupply is only dust
```

```text
victim deposit:
  -> victim calls IERC4626(dreUSDs).deposit(assets, victim)
      -> ERC4626Upgradeable.deposit(assets, receiver)
          -> shares = previewDeposit(assets)
              -> _convertToShares(assets, Math.Rounding.Floor)
                  -> uses totalSupply() + 1
                  -> uses totalAssets() + 1
                  -> with dust supply and large vested rewards, shares can be 0 or severely underpriced
          -> dreUSDs._deposit(caller, receiver, assets, shares)
              -> _virtualBalance += _claimVestedRewards()
                  -> rewardsDistributor.claimVested()
                  -> distributor transfers vested dreUSD to dreUSDs
              -> _virtualBalance += assets
              -> super._deposit(caller, receiver, assets, shares)
                  -> transfers victim dreUSD into the vault
                  -> mints the already-computed shares amount
```

```text
checks:
  -> victim dreUSD balance decreased by assets
  -> victim dreUSDs balance increased by 0 or near-zero shares
  -> victim's deposit is included in _virtualBalance
  -> dreUSDs.excessDreUSD() does not recover the victim deposit
  -> dust holder remains under-diluted and can redeem rewards plus part/all of the victim deposit
```

```text
zero-supply subcase:
  -> if the attacker exits fully, or if rewards vest before any real deposit, totalSupply can be 0
  -> then the same formula uses only the OZ virtual share offset
  -> deposits can mint exactly 0 shares when assetsIn < totalAssets + 1
```

### Why this is strong

This is not merely that late depositors do not receive old rewards. That part is expected. New depositors should be priced at the current exchange rate so their shares represent their own deposited value. The bug is that dust supply plus vested rewards can make the ERC4626 conversion mint zero or severely underpriced shares, giving the new depositor less ownership than their own deposit should buy.

The issue is reachable without requiring rewards to be scheduled while the vault is empty. Temporary capital can be present at scheduling time and exit before the rewards vest. Because rewards vest linearly over 7 days, the attack window appears once `vestedAmount()` becomes large enough relative to the remaining dust supply.

Existing slippage checks only protect selected wrapper routes if users set `minSharesOut` / `minAmountLD` correctly. The underlying ERC4626 `deposit()` remains public and has no minimum-share parameter, so the invariant must be enforced in `dreUSDs` or in reward scheduling itself.

### Impact

- Direct ERC4626 depositors can receive `0` or severely underpriced shares for a nonzero dreUSD transfer.
- A dust-share holder can retain disproportionate ownership and redeem vested rewards plus a large fraction of later victim deposits.
- Safe wrapper routes with nonzero `minSharesOut` can revert, causing a deposit liveness issue while the vault remains in the toxic dust-supply state.
- Victim deposits are not recoverable via `withdrawExcessDreUSD()` because `_virtualBalance` accounts for them.

### PoC

PoC tests are in `dreusd/test/PoC_Findings.t.sol` and `dreusd/test/PoC_H01_TemporaryCapital.t.sol`:

- `testPoC_FirstDepositAfterRewardsAccruedMintsZeroSharesAndTrapsAssets()`
- `testPoC_DustShareHolderCapturesVictimDepositAfterRewardsAccrue()`
- `testPoC_TemporaryCapitalCanEnableRewardsThenExitBeforeVestingLeavingDustSupplyTrap()`

The temporary-capital dust-supply variant was run in a minimal Foundry harness with the real `dreUSDs` and `dreRewardsDistributor` contracts. The logs show that for a `1,000 dreUSD` victim deposit and `7,000 dreUSD` rewards vesting over 7 days, `previewDeposit()` falls to `1 wei share` after 1 day and `0 shares` after 2 days:

```text
[PASS] testPoC_TemporaryCapitalCanEnableRewardsThenExitBeforeVestingLeavingDustSupplyTrap()
1 passed; 0 failed
```

The full repo test command is currently blocked by unrelated LayerZero remapping/dependency errors before it reaches this PoC.

### Recommended Fix

Consider one or more of:

- Reject `addRewards()` / `mintRewards()` unless `dreUSDs.totalSupply()` is above a meaningful minimum.
- Enforce a maximum reward-to-staked-assets or reward-to-share-supply ratio at scheduling time.
- Require protocol-owned locked seed liquidity that cannot exit during the reward vesting window.
- Revert deposits when `assets > 0 && shares == 0`, and consider a minimum-share or minimum-ownership guard for dust-supply states.
- Require safe `minSharesOut` on every user-facing staking route, while still protecting the underlying ERC4626 vault against unsafe direct deposits.


Minimal illustrative patch:

```diff
diff --git a/dreusd/contracts/dreUSDs.sol b/dreusd/contracts/dreUSDs.sol
@@
 contract dreUSDs is
@@
 {
@@
+    error ZeroShares();
@@
     function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
+        if (assets > 0 && shares == 0) revert ZeroShares();
         _virtualBalance += _claimVestedRewards();
         _virtualBalance += assets;
         super._deposit(caller, receiver, assets, shares);
     }
diff --git a/dreusd/contracts/dreRewardsDistributor.sol b/dreusd/contracts/dreRewardsDistributor.sol
@@
 contract dreRewardsDistributor is
@@
 {
@@
+    error InsufficientVaultShareSupply(uint256 currentSupply, uint256 minimumSupply);
+
+    /// @dev Example value only. Governance should set this from protocol launch/runbook assumptions.
+    uint256 public minimumVaultShareSupplyForRewards;
+
+    function setMinimumVaultShareSupplyForRewards(uint256 minimumSupply)
+        external
+        onlyRole(DEFAULT_ADMIN_ROLE)
+    {
+        minimumVaultShareSupplyForRewards = minimumSupply;
+    }
@@
     function addRewards() external onlyRole(MODERATOR_ROLE) whenNotPaused {
+        uint256 supply = IERC20(vault).totalSupply();
+        uint256 minSupply = minimumVaultShareSupplyForRewards;
+        if (supply < minSupply) {
+            revert InsufficientVaultShareSupply(supply, minSupply);
+        }
+
         IdreUSDs(vault).claimVestedRewards();
         // compute added rewards that are not yet vested
         uint256 newRewards = IERC20(dreUSD).balanceOf(address(this)) - rewards;
```

The `ZeroShares` guard prevents direct ERC4626 deposits from silently transferring assets for no shares. The reward-supply guard prevents new reward streams from being scheduled while `dreUSDs` has zero/dust share supply; in production, the threshold should be set high enough that expected reward emissions cannot dominate the remaining share supply.

