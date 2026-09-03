# [Design-dependent; potential High impact] Deposits made after oracle consensus capture rewards accrued before the deposit

> **Final assessment: design-dependent; not a confirmed High-severity vulnerability.**
> The PoC demonstrates a real and measurable transfer of historical rewards to
> post-consensus depositors. However, classifying that transfer as a vulnerability
> depends on the protocol's intended rebasing semantics. If every share existing at
> execution is intentionally entitled to the next rebase, regardless of when the
> underlying rewards accrued, this is protocol design rather than a security-boundary
> violation. The potential `High` impact classification describes the potential economic impact under the
> alternative invariant that rewards belong only to holders exposed during the reported
> interval; it should not be read as the final validity verdict.

## Summary

Ether.fi applies an oracle report's `accruedRewards` to the eETH share supply that exists when `EtherFiAdmin.executeTasks()` is executed. The report, however, describes rewards accrued during an earlier, already completed reference interval.

After a positive report reaches consensus, the report and its exact `accruedRewards` value are public, and the mandatory post-report waiting period prevents immediate execution. During this window, `LiquidityPool.deposit()` remains permissionless. An attacker can deposit ETH at the pre-report exchange rate, receive newly minted eETH shares, wait for the normal authorized executor to execute the report, and receive a pro-rata portion of rewards earned before the attacker deposited.

The attacker can then use the ordinary, public `WithdrawRequestNFT` path. Subsequent honest oracle reports finalize the requests, and `claimWithdraw()` transfers native ETH to the attacker with no instant-redemption fee.

This is a deterministic transfer of unclaimed yield from existing eETH holders to the attacker. It does not require a malicious oracle, executor, administrator, node operator, pauser, or third-party protocol.

**Potential impact mapping:** High — direct capture of material unclaimed yield, if the
protocol is intended to exclude post-interval depositors from historical rewards.

**Final classification:** Design-dependent economic behavior, with High impact only if
that historical-ownership invariant is part of the protocol's intended security model.

## Reasons for invalidation or downgrade

Even if the accounting mechanism is accepted, the following points materially weaken a
High-severity classification and may cause the report to be treated as invalid, known,
or economically impractical:

1. **Recent normal reports support only limited gross capture.** With the currently
   available 30,000 ETH mint capacity, recent ordinary reports permit approximately
   `0.37 ETH` of gross reward capture. That amount is likely unprofitable after
   withdrawal latency, financing costs, opportunity cost, and gas. This weakens the
   practical impact even though the accounting effect remains measurable.
2. **The `5.18 ETH` example mixes historical and current conditions.** It combines a
   2024 oracle report and historical TVL with the current 30,000 ETH mint capacity. It
   demonstrates the mechanism against a report that occurred on-chain, but it does not
   prove that the same capital could have entered under the configuration that existed
   at that historical block. It must therefore be presented as a counterfactual rather
   than a historically executable attack.
3. **There is substantial known-issue or duplicate risk.** Certora's 2026 threat model
   already discusses deposits bundled with report execution as a source of
   "risk-free yield." Even if the exact historical-denominator formulation or async
   native-ETH exit differs, the protocol may consider the general reward-capture
   behavior known, intended, or already covered by that threat model.

Together with the design-dependent rebasing invariant, these points mean the report
should not be presented as an unconditional High finding. The strongest defensible
description is a technically demonstrated economic behavior whose present
profitability, historical executability, novelty, and violation of intended protocol
semantics remain uncertain.

**Primary affected contracts:**

- `EtherFiOracle.sol`
- `EtherFiAdmin.sol`
- `LiquidityPool.sol`
- `EETH.sol`
- `WithdrawRequestNFT.sol`

## Verified mainnet-fork result

The current-deployment PoC was run at Ethereum block `25,655,889` on 31 July 2026. It uses:

- a report containing exactly 24 hours of rewards at 5% APR;
- a valid, quantized report interval of 92,160 seconds, making the effective report APR 461 bps;
- the live 30,000 ETH eETH mint capacity;
- the live 1,000 ETH maximum withdrawal size;
- the live 80,000 ETH/day finalization limit;
- the live 3,500 requests-per-report limit;
- the live 25,000 ETH global burn capacity;
- three normal withdrawal-finalization reports; and
- final custody in native ETH.

The result is:

```text
[PASS] test_currentMainnet_24HourFivePercentAprReturnsCapitalAndPositiveNativeEthProfit()

one-day accrued rewards:             271.202733246602307817 ETH
attacker capital:                  29,999.999999999000000000 ETH
captured historical rewards:          4.048245175531153656 eETH
final native ETH custody:          30,004.048245174531153656 ETH
attacker profit:                       4.048245175531153656 ETH
normal finalization reports:           3
```

The PoC commits all attacker capital to `LiquidityPool.deposit()`, returns the complete principal through ordinary withdrawal NFTs, and leaves the attacker with `4.048245175531153656 ETH` of native-ETH profit.

## Root cause

The protocol uses two different temporal states for a single reward distribution:

1. `accruedRewards` is measured for the historical interval ending at `report.refSlotTo`.
2. Reward ownership is determined using the live eETH share supply at the later `executeTasks()` transaction.

There is no snapshot of `eETH.totalShares()` at the report's reference boundary, and shares minted after consensus are not excluded from the already-accrued reward.

The vulnerable state transition is:

```text
historical interval ends
        |
        | rewards R accrue to the old holders
        v
oracle report reaches consensus and publicly commits R
        |
        | deposits remain open during the mandatory waiting window
        v
attacker receives new shares using the pre-report TVL
        |
        v
executeTasks() adds historical R to pooled ether
        |
        v
all currently existing shares, including the attacker's new shares,
are now redeemable for R
```

### Vulnerable deposit accounting

The attacker calls the public entry point:

```solidity
LiquidityPool.deposit{value: A}()
```

The call reaches `_deposit(attacker, A, 0)`, which first adds the ETH to `totalValueInLp` and then calculates shares:

```solidity
totalValueInLp += uint128(_amountInLp);
uint256 share = _sharesForDepositAmount(amount);
eETH.mintShares(_recipient, share);
```

`_sharesForDepositAmount()` subtracts the just-added deposit and prices the deposit against the pre-report pooled ether:

```solidity
uint256 totalPooledEther = getTotalPooledEther() - _depositAmount;
return (_depositAmount * eETH.totalShares()) / totalPooledEther;
```

This correctly gives the attacker shares at the current on-chain exchange rate, but that rate does not yet include the positive `accruedRewards` already committed by the oracle report.

### Vulnerable rebase accounting

After the mandatory wait, the authorized executor calls:

```solidity
EtherFiAdmin.executeTasks(report)
```

The relevant call chain is:

```text
EtherFiAdmin.executeTasks(report)
    -> EtherFiAdmin._handleAccruedRewards(report)
        -> MembershipManager.rebase(report.accruedRewards)
            -> LiquidityPool.rebase(report.accruedRewards)
```

`LiquidityPool.rebase()` increases pooled ether without minting or snapshotting shares:

```solidity
totalValueOutOfLp = uint128(int128(totalValueOutOfLp) + _accruedRewards);
```

Because the attacker's shares already exist at this point, `amountForShare()` and `eETH.balanceOf()` immediately assign part of the historical reward to those shares.

The root cause is therefore not the oracle supplying corrupt information. The report can be fully valid. The flaw is that a historical numerator (`accruedRewards`) is distributed over a later, attacker-inflatable denominator (`eETH.totalShares()`).

## Accounting proof

Let:

- `P` be pooled ether immediately before the attacker deposit, excluding the unbooked report reward;
- `S` be the existing eETH share supply;
- `R` be the positive historical `accruedRewards`; and
- `A` be the attacker deposit.

The deposit mints:

```text
attackerShares = A * S / P
```

After the deposit and report execution:

```text
total pooled ether = P + A + R
total shares        = S + A*S/P
```

The attacker's post-rebase claim is:

```text
attackerValue
  = attackerShares * (P + A + R) / totalShares
  = A + A*R/(P + A)
```

Therefore:

```text
captured historical rewards = A * R / (P + A)
```

Without the vulnerability, the new depositor should retain value `A`, while the holders who owned shares during the historical interval should receive `R`. Instead, existing holders collectively lose `A*R/(P+A)`, and the attacker gains the same amount.

## Exact attack operations and functions

### Phase 1 — a legitimate report becomes public

1. Oracle members calculate an ordinary positive report for a completed reference interval.
2. Committee members call `EtherFiOracle.submitReport(report)`.
3. When quorum is reached, `EtherFiOracle._publishReport()` stores `lastPublishedReportRefSlot` and emits `ReportPublished`.
4. `accruedRewards`, the reference interval, and the consensus event are now observable on-chain.
5. `EtherFiAdmin.executeTasks()` cannot execute until `postReportWaitTimeInSlots` has elapsed.

No malicious or compromised oracle is required. The attacker only waits for an honest report with positive rewards.

### Phase 2 — the attacker enters after the rewards have accrued

The attacker calls:

```text
LiquidityPool.deposit{value: A}()
    -> LiquidityPool.deposit(address(0))
        -> LiquidityPool._deposit(attacker, A, 0)
            -> LiquidityPool._sharesForDepositAmount(A)
            -> EETH.mintShares(attacker, attackerShares)
```

Relevant state changes:

```text
LiquidityPool.totalValueInLp += A
EETH.shares[attacker]         += A*S/P
EETH.totalShares              += A*S/P
```

The report reward `R` has not yet been added to `getTotalPooledEther()`, so the attacker receives the pre-rebase number of shares.

### Phase 3 — normal report execution credits the attacker

After the configured wait, the normal executor calls:

```text
EtherFiAdmin.executeTasks(report)
    -> checks report consensus, reference slots, reference blocks and wait time
    -> EtherFiAdmin._handleAccruedRewards(report)
        -> validates the report APR
        -> MembershipManager.rebase(R)
            -> LiquidityPool.rebase(R)
                -> totalValueOutOfLp += R
```

`EETH.totalShares` is not changed by the rebase. Consequently, the value of every existing share rises, including the shares minted to the attacker after report consensus.

### Phase 4 — the attacker converts the captured yield into native ETH

The attacker uses only public functions:

```text
EETH.approve(LiquidityPool, amount)

LiquidityPool.requestWithdraw(attacker, amount)
    -> LiquidityPool.sharesForAmount(amount)
    -> EETH.transferFrom(attacker, WithdrawRequestNFT, amount)
    -> WithdrawRequestNFT.requestWithdraw(amount, shares, attacker, fee = 0)
    -> withdrawal NFT is minted to attacker
```

Subsequent ordinary reports finalize the globally ordered requests:

```text
EtherFiOracle.submitReport(followUpReport)
    -> report reaches consensus

EtherFiAdmin.executeTasks(followUpReport)
    -> EtherFiAdmin._handleWithdrawals(followUpReport)
    -> WithdrawRequestNFT.finalizeRequests(lastFinalizedRequestId)
    -> LiquidityPool.addEthAmountLockedForWithdrawal(finalizedAmount)
```

Finally, the attacker calls:

```text
WithdrawRequestNFT.claimWithdraw(tokenId)
    -> WithdrawRequestNFT._claimWithdraw(tokenId, attacker)
    -> LiquidityPool.withdraw(attacker, claimableAmount)
        -> EETH.burnShares(WithdrawRequestNFT, shares)
        -> LiquidityPool._sendFund(attacker, claimableAmount)
```

The final asset is native ETH under the attacker's custody. This is not merely an eETH price movement, depeg, third-party loss, or unrealized accounting gain.

## Attack preconditions

The attack requires:

1. a positive oracle report that has reached consensus but has not yet been executed;
2. a reporting interval large enough that captured rewards exceed capital cost and gas;
3. available eETH mint capacity;
4. attacker capital; and
5. normal future oracle and executor operation to finalize the withdrawal NFTs.

The attacker does **not** require:

- an oracle committee role;
- an executor role;
- an owner, admin, multisig, pauser, or node-operator role;
- a priority-withdrawal whitelist;
- a compromised role;
- invalid oracle data;
- a malicious third-party protocol; or
- permanent freezing of any funds.

This is not an atomic flash-loan attack because the native-ETH exit is asynchronous. It is feasible for a sufficiently capitalized actor or an actor with term financing.

In the verified 24-hour fork case, three report periods are needed to finalize approximately 30,004 ETH. At a hypothetical 5% annual capital cost, roughly 12.8 hours on 30,000 ETH costs approximately 2.2 ETH, leaving about 1.8 ETH before gas. Financing conditions can change this result, but the direct on-chain extraction remains `4.048245175531153656 ETH`.

## Why the post-consensus window is exploitable

The final report submission emits the report and establishes consensus before execution is permitted. The deployed post-report wait therefore creates a public deterministic window. Private transaction submission by the executor does not remove this window: the attacker can deposit after `ReportPublished` and before the earliest valid execution slot.

Manual pausing, blacklisting, request invalidation, or governance intervention may react to a detected attacker, but none is an automatic on-chain invariant that prevents the reward capture.

## Historical feasibility

A scan of 3,755 executed mainnet reports found:

- a largest positive reference interval of 2 days 10 hours 46 minutes;
- `222.55994380339993 ETH` of `accruedRewards` in that report; and
- a largest consensus-to-execution window of 1 day 19 hours 22 minutes.

For the largest observed positive report, using its historical TVL and a counterfactual 30,000 ETH post-consensus deposit gives:

```text
222.5599438 * 30,000 / (1,258,213.8687 + 30,000)
  = 5.182989 ETH
```

This historical calculation is evidence that multi-day positive report intervals occur, but it is not presented as proof that today's mint and exit limits existed at that historical block.

The PoC also verifies a conditional maximum under the currently deployed 25-bps positive-rebase cap:

```text
[PASS] test_deployedMintLimitStillAllowsOver73EthExtraction()
captured historical rewards: 73.880474453443554246 eETH
final native-ETH profit:      73.880474453443554246 ETH
```

That stress case requires approximately a 19-day reporting interval at the 5% APR bound. No comparable interval was found in the historical scan, so `73.88 ETH` must not be treated as the normal or historically observed impact. The 24-hour `4.048 ETH` fork result is the primary reproducible example.

## Impact

Existing eETH holders earned the reported rewards by holding shares during the report's historical reference interval. A post-consensus depositor did not bear that time exposure but receives part of those rewards.

For the verified 24-hour scenario:

- existing holders lose `4.048245175531153656 ETH` of unclaimed yield;
- the attacker obtains the same value;
- the attacker exits through Ether.fi's native withdrawal contracts; and
- the attacker ends with an additional `4.048245175531153656 ETH` in native-ETH custody.

The protocol remains nominally solvent because this is a redistribution inside the eETH backing pool. Solvency does not remove the theft: existing holders' enforceable pro-rata claim is reduced and the attacker receives the difference.

## Proof of concept

PoC source:

```text
my-audit/pocs/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol
```

The source includes an ABI compatibility shim because the checked-out interface contains an 11-field `OracleReport`, while the mainnet proxies at the tested block use the deployed 10-field report tuple. This affects only the test harness selectors; it is not the vulnerability.

Run from the Ether.fi repository root:

```bash
cp my-audit/pocs/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol \
  test/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol

MAINNET_RPC_URL="YOUR_MAINNET_RPC_URL" forge test \
  --match-path test/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol \
  --match-test test_currentMainnet_24HourFivePercentAprReturnsCapitalAndPositiveNativeEthProfit \
  -vv
```

Run the conditional 25-bps stress case with:

```bash
MAINNET_RPC_URL="YOUR_MAINNET_RPC_URL" forge test \
  --match-path test/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol \
  --match-test test_deployedMintLimitStillAllowsOver73EthExtraction \
  -vv
```

The RPC must support normal Foundry mainnet forking. The tests do not execute transactions on mainnet.

## Scope and privileged-role analysis

The PoC impersonates the real committee and authorized executor only to advance a legitimate report and subsequent legitimate finalization reports inside the fork. Those actors do not deviate from their normal roles and do not collude with the attacker.

The actual attacker operations are only:

1. `LiquidityPool.deposit()`;
2. `EETH.approve()`;
3. `LiquidityPool.requestWithdraw()`; and
4. `WithdrawRequestNFT.claimWithdraw()`.

All are public operations. The vulnerability's root cause is in Ether.fi's report-to-rebase accounting and the permissionless deposit flow, not in external oracle infrastructure or another protocol.

Although `MembershipManager.rebase()` appears in the call path, the affected accounting is the core eETH exchange rate in `LiquidityPool.rebase()`. The loss and gain occur between eETH holders and a public depositor; the finding is not limited to ether.fan membership rewards.

## Difference from known findings

The closest previous finding is Certora M-11, "Donation of EETH share can lead to executeTasks DOS." It is not the same vulnerability:

| Aspect | Certora M-11 | This finding |
| --- | --- | --- |
| Attacker action | Donate or burn eETH shares affecting `MembershipManager` | Make an ordinary public ETH deposit |
| Root cause | Manipulable membership balance can make a reward delta zero and trigger division by zero | Historical rewards use the live, post-consensus eETH share denominator |
| Primary result | `executeTasks()` denial of service | Direct capture and native-ETH withdrawal of existing holders' yield |
| Required effect | Corrupt the ether.fan reward calculation | Successfully execute the otherwise-valid oracle report |

M-12 and the later eETH share-inflation finding concern permissionless `burnShares()` and manipulated deposit pricing. This attack does not call `burnShares()` and does not require share inflation. The instant-stETH reward-dilution finding concerns retained eETH after redemption; the primary path here uses fee-free native withdrawal NFTs.

## Recommended remediation

The reward denominator must be aligned with the interval for which rewards accrued.

Possible fixes, from strongest to more tactical:

1. Track/checkpoint eETH share supply and distribute report rewards using the share supply at the report's reference boundary.
2. Queue deposits made while a consensused report is pending and mint their shares only after that report is executed, using the post-rebase exchange rate.
3. Assign a reward debt to shares minted after the report's reference boundary so they cannot participate in already-accrued rewards.
4. Redesign report publication and execution so no public deposit window exists between committing the reward and applying it.

Merely using private executor transactions or shortening the wait reduces exposure but does not restore the missing accounting invariant.

## Security invariant

For any positive report covering `[refSlotFrom, refSlotTo]`, shares minted after `refSlotTo` must not receive any part of that report's `accruedRewards`.

A regression test should assert that:

```text
deposit after report consensus
execute the pending positive report
withdraw the depositor's entire position
```

returns no more than the depositor's principal, apart from rewards that accrue after the deposit and explicitly belong to a later report.
