# Candidate: Instant Redemption Can Invalidate a Consensused Withdrawal Report

## Status

- **Status:** Reproduced; economic sibling reproduced under a delayed positive report
- **Provisional severity:** Low for liquidity invalidation; High impact mapping for the positive-rebase sandwich
- **Direct loss demonstrated:** Yes for the economic sibling; no for the original liquidity invalidation
- **Permanent DoS demonstrated:** No
- **Reviewed revision:** `b4a0968087b178bc346cdf6bee6c0597bf4c42c7` (`origin/master`, 2026-07-15)
- **PoC result:** Liveness and economic PoCs pass; see `my-audit/ECONOMIC_REBASE_ESCALATION.md`

## Summary

An oracle report can reach consensus and initially pass `EtherFiAdmin.canExecuteTasks()`, but become non-executable before `executeTasks()` is called.

The cause is that `finalizedWithdrawalAmount` is checked against the current `LiquidityPool.totalValueInLp()` only at execution time. The amount is not reserved when the report reaches consensus. During the publication-to-execution gap, any eligible eETH or weETH holder can use `EtherFiRedemptionManager` to redeem against the same LP liquidity.

If that redemption reduces `totalValueInLp` below the report's `finalizedWithdrawalAmount`, execution reverts. Because the report is already published but not handled, subsequent oracle reports are also blocked until the operating multisig unpublishes the invalid report and the committee reaches consensus again.

## Affected components

- `src/oracle/EtherFiAdmin.sol`
  - `executeTasks()`
  - `_validateWithdrawals()`
- `src/oracle/EtherFiOracle.sol`
  - `shouldSubmitReport()`
  - `unpublishReport()`
- `src/withdrawals/EtherFiRedemptionManager.sol`
  - `_processETHRedemption()`
  - `getInstantLiquidityAmount()`
- `src/core/LiquidityPool.sol`
  - `withdraw(address,uint256)`

## Root cause

The protocol has two consumers of the same mutable liquidity:

1. A consensused oracle report expects to lock `finalizedWithdrawalAmount` ETH for queued withdrawals.
2. The public instant-redemption path can remove ETH from `totalValueInLp` before that lock is performed.

Consensus commits to a withdrawal amount but does not create an LP reservation for it.

`EtherFiAdmin._validateWithdrawals()` effectively requires:

```text
finalizedWithdrawalAmount <= liquidityPool.totalValueInLp()
```

`EtherFiRedemptionManager._processETHRedemption()` subsequently decreases `totalValueInLp` when paying an instant redemption. The validation is run again by `executeTasks()`, so a report that was valid after consensus can later fail.

## Attack flow

```text
Queued withdrawal requests exist
        |
        v
Oracle committee publishes report with finalizedWithdrawalAmount = W
        |
        v
canExecuteTasks(report) == true
        |
        v
User/attacker instant-redeems eETH or weETH for ETH
        |
        v
LiquidityPool.totalValueInLp decreases from L0 to L1
        |
        v
L1 < W
        |
        v
canExecuteTasks(report) == false
executeTasks(report) reverts
        |
        v
New oracle reports revert with LastReportNotHandled
        |
        v
Operating multisig must unpublish; committee must resubmit
```

## Feasibility condition

Let:

- `L0` be `totalValueInLp` when the report becomes executable;
- `W` be `finalizedWithdrawalAmount` in the published report;
- `R` be the net ETH removed through instant redemption;
- `M` be the redemption manager's low watermark.

The report is initially valid when:

```text
W <= L0
```

It becomes invalid when:

```text
L0 - R < W
```

Therefore, the minimum required redemption is:

```text
R > L0 - W
```

The low watermark does not reserve `W`. Subject to bucket capacity and the attacker's token balance, the redemption path can consume liquidity down toward `M`. The race is consequently feasible when the available redemption capacity crosses the report's remaining liquidity headroom. In particular, `W > M` makes the watermark alone insufficient.

## Reproduced scenario

The passing test uses:

- initial LP liquidity: `80 ETH`;
- queued request: `60 ETH`;
- published `finalizedWithdrawalAmount`: `60 ETH`;
- eETH backed by protocol assets outside the immediately liquid LP: `100 eETH`;
- instant redemption input: `30 eETH`;
- exit fee: `50 bps` (`0.5%`);
- low watermark: `500 bps` (`5%` of TVL, the contract's maximum configurable ceiling in the reviewed code);
- redemption bucket capacity: `100 ETH`.

Before redemption:

```solidity
assertTrue(etherFiAdminInstance.canExecuteTasks(report));
```

After redemption:

```solidity
assertLt(liquidityPoolInstance.totalValueInLp(), 60 ether);
assertFalse(etherFiAdminInstance.canExecuteTasks(report));
```

Execution then reverts with:

```text
EtherFiAdmin: finalized withdrawal exceeds LP liquidity
```

Test command and result from the isolated `origin/master` review snapshot (the PoC test itself has not been added to this working tree):

```text
forge test \
  --match-path test/RebaseOutOfLpSignedWrapPoC.t.sol \
  --match-test test_publicRedemptionInvalidatesConsensusedWithdrawalReport \
  -vv

[PASS] test_publicRedemptionInvalidatesConsensusedWithdrawalReport()
```

## Impact currently demonstrated

- Finalization of the affected queued withdrawals is delayed.
- The rebase and validator-approval task included in the same `executeTasks()` call are also delayed because execution is atomic.
- Oracle progression is blocked because `lastPublishedReportRefSlot` is ahead of `lastHandledReportRefSlot`.
- Operations must detect the failure, invoke the privileged `unpublishReport()` recovery path, reconstruct the report, and obtain committee consensus again.
- A public user can trigger the condition through an otherwise legitimate redemption operation.

No theft, permanent lock, or irreversible accounting corruption has been demonstrated. The report can be recovered by the operating multisig, and the redeemer must own eETH/weETH and pay the configured exit fee.

## Why existing mitigations are incomplete

### Low watermark

The low watermark protects a percentage of total TVL. It does not protect the amount committed to the pending withdrawal report. It prevents this race only if the protected liquidity is always at least the pending finalization requirement.

### Bucket limiter

The bucket limiter caps redemption volume, but the attack requires only enough redemption to consume the report's liquidity headroom, `L0 - W`. A report close to current liquidity can be invalidated by a comparatively small redemption.

### Execution-time validation

Revalidation prevents an underfunded lock and therefore avoids insolvency. It converts the state race into a report-liveness failure rather than resolving the competing liquidity commitments.

### Unpublish recovery

`unpublishReport()` makes the failure recoverable, but it is privileged and requires operational intervention followed by new committee submissions. It does not stop repeatable disruption.

## Higher-impact leads to test next

### 1. Repeatable oracle griefing

Determine whether an attacker can invalidate each replacement report using small redemptions near the liquidity boundary. Measure:

- minimum eETH/weETH capital required;
- exit-fee cost per cycle;
- bucket refill rate and capacity;
- operating-multisig response time;
- whether newly arriving LP liquidity lets the attacker recycle the strategy;
- total time that rebases, validator approvals, and withdrawals can be delayed.

A cheap and repeatable stall could elevate the finding beyond a one-time operational inconvenience.

### 2. Negative-rebase loss avoidance

A published report reveals `accruedRewards` before execution. If the value is negative, an eETH/weETH holder may be able to redeem at the pre-rebase rate, avoid its portion of the loss, and leave the entire negative adjustment to remaining holders.

The important comparison is:

```text
avoided negative-rebase loss
    versus
exit fee + execution costs + acquisition costs
```

Test whether the same redemption can both:

1. exit before the negative rebase; and
2. invalidate the report, delaying recognition of the loss.

This would change the impact from pure liveness to economic loss redistribution.

### 3. Positive-rebase deposit sandwich

For a positive `accruedRewards` report, test whether an attacker can:

1. observe the consensused report;
2. deposit ETH at the pre-rebase share price;
3. call the permissionless `executeTasks(report)`;
4. exit after receiving a portion of rewards accrued before the deposit.

The positive rebase is capped, so profitability depends on the deposit limiter, instant-redemption fee, bucket liquidity, and possible alternative exit routes. A profitable atomic or bundled transaction would provide direct economic impact.

### 4. Mempool ordering

Test direct front-running of an `executeTasks()` transaction rather than relying only on the normal post-consensus delay. Establish whether private execution is consistently used off chain; private submission would mitigate ordinary mempool front-running but would not be an on-chain invariant.

### 5. Production-parameter proof

Read the deployed values and recent report history for:

- ETH redemption low watermark;
- bucket capacity and refill rate;
- ETH exit fee;
- `postReportWaitTimeInSlots`;
- typical `totalValueInLp` at report publication;
- typical `finalizedWithdrawalAmount`;
- unpublish/recovery latency.

The strongest production proof would identify a historical or current report for which:

```text
totalValueInLp - finalizedWithdrawalAmount
    < publicly redeemable ETH
```

## Potential fixes

Possible designs include:

1. Reserve `finalizedWithdrawalAmount` when the report reaches consensus and exclude it from instant-redeemable liquidity.
2. Make ETH instant liquidity equal to:

   ```text
   totalValueInLp - max(lowWatermark, pendingOracleWithdrawalReserve)
   ```

3. Atomically bind report publication to a liquidity reservation.
4. Prevent ETH instant redemptions from consuming liquidity required by the currently published report.
5. Add a safe, narrowly scoped recovery path for reports that become invalid solely because public protocol operations changed execution-time state.

Any reservation must be released when the report executes or is unpublished.

## Scope and novelty notes

- The exact oracle-report/instant-redemption interaction was not found in the reviewed tests or comments.
- EtherFi separately documents the post-finalization negative-rebase claim underflow in `test/LpRebaseWrnClaimUnderflow.t.sol` as an architectural finding. That known issue must not be merged into this candidate's novelty claim.
- This candidate concerns a report that was valid after consensus but was invalidated by a later public state transition before execution.
- Until direct loss or inexpensive repeatability is proven, present it conservatively as a recoverable report-liveness/griefing issue.

