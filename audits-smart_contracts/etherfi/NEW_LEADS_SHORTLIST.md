# Ether.fi — New Lead Shortlist

Review point: commit `b4a09680`. These are hypotheses for quick PoCs, not confirmed findings. The existing positive-rebase capture/race is intentionally excluded. Known full-exit rate-limiter and stETH small-remainder issues are also excluded as duplicates.

## Ranked leads

| Rank | Lead | Promise | Access / scope risk |
|---:|---|---|---|
| 1 | Execution-time TVL can weaken a consensused report's safety limits | High | Public deposit; impact may still depend on an abnormal oracle report |
| 2 | Validator-approval task does not commit the pubkeys or signatures later funded | Medium–High | Execution is oracle-operations gated |
| 3 | Public stETH redemption competes with finalized withdrawals for the same `totalValueOutOfLp` headroom | Medium | Public, but requires a tight accounting state |
| 4 | Consolidation limiter charges 32 ETH even when a compounding validator moves more | Medium | Executor role required; confirm Pectra/mainnet configuration |
| 5 | EigenLayer withdrawal limiter uses pre-slashing `depositShares` as ETH | Medium–Low | Executor role required; likely liveness rather than theft |
| 6 | EigenPod forwarding allowlist binds only the selector, not sensitive arguments | Medium–Low | EigenPod-operations role required |
| 7 | Deposit adapter converts shares to amount and back, potentially accumulating user-funded dust | Low | Public; likely only rounding dust unless fuzzing shows scaling |

## 1. Mutable TVL weakens report safety checks

- **Code:** `EtherFiAdmin._validateRebaseApr()` and `LiquidityPool.rebase()`.
- **Hypothesis:** both the APR denominator and positive/negative absolute caps use live execution-time TVL. After oracle consensus but before `executeTasks()`, a public deposit can increase TVL and turn a previously rejected report into an executable one.
- **Possible impact:** bypass of the protocol's report circuit breaker; strongest impact requires showing that a realistic consensused report is unsafe at its reference state but accepted after the deposit.
- **Kill test:** prepare a report that fails before a deposit, deposit the minimum calculated amount, then prove `canExecuteTasks`/`executeTasks` succeeds.
- **Triage risk:** adjacent to, but distinct from, the reward-capture finding. It may be dismissed if the only consequence is ordinary rebase participation or if the report must already be malicious.

## 2. Approval task commits IDs but not funded keys

- **Code:** `EtherFiAdmin.executeValidatorApprovalTask()` / `_approveValidators()` and `StakingManager.confirmAndFundBeaconValidators()`.
- **Hypothesis:** consensus and `taskHash` commit `_validators`, while `_pubKeys` and `_signatures` are supplied later by the executor. A key can pass if it is already linked and resolves to compatible EigenPod withdrawal credentials. Keys within the same pod are the most promising swap case.
- **Possible impact:** the remaining validator deposit is sent to a registered validator that was not the key intended when the task was reported.
- **Kill test:** enqueue validator ID A, execute with registered pubkey B under the same EigenPod, and check whether the remaining deposit reaches B.
- **Triage risk:** a malicious oracle-operations actor is normally out of scope. Continue only if an unprivileged party can influence the late arguments or the mismatch can occur during normal automation.

## 3. stETH redemption can consume finalized-claim accounting headroom

- **Code:** `EtherFiRedemptionManager._processStETHRedemption()`, `LiquidityPool.burnEEthSharesForNonETHWithdrawal()`, and `LiquidityPool.withdraw()`.
- **Hypothesis:** finalized ETH claims and staking/restaking assets share `totalValueOutOfLp`. A public instant stETH redemption subtracts from that same counter even though finalized ETH is already segregated in WRNFT/PWQ. It may push the counter below a finalized claim and make the later claim underflow.
- **Possible impact:** temporary freezing of already-finalized withdrawals despite the escrow holding the ETH.
- **Kill test:** finalize a large claim, leave small `totalValueOutOfLp` headroom, perform an allowed stETH redemption, then claim the finalized NFT.
- **Triage risk:** related negative-rebase underflow behavior is already known; the report must prove this independent public-redemption trigger and a realistic mainnet state.

## 4. Consolidation rate limit assumes every moved balance is 32 ETH

- **Code:** `EtherFiNodesManager.requestConsolidation()` / `_getTotalConsolidationGwei()`.
- **Hypothesis:** every true consolidation consumes `FULL_EXIT_GWEI` (32 ETH), although the comment acknowledges that the source's full balance is merged. A 0x02 compounding validator can hold materially more than 32 ETH.
- **Possible impact:** consolidation can move much more beacon ETH than the configured safety limiter records.
- **Kill test:** model a source validator above 32 ETH and compare actual consolidated balance with limiter consumption.
- **Duplicate check:** known issues cover fixed-32-ETH **full exits** and consolidation overconsumption; this underconsumption direction appears different but must be checked against the 2025 consolidation audit PDF.

## 5. Restaking withdrawal limiter uses `depositShares`

- **Code:** `EtherFiNodesManager.queueWithdrawals()` / `_sumRestakingETHWithdrawals()`.
- **Hypothesis:** the limiter sums Beacon ETH `depositShares` directly as wei. EigenLayer explicitly distinguishes slashing-adjusted withdrawable shares from deposit shares. After slashing/scaling, the counter may no longer equal the economic ETH queued.
- **Possible impact:** likely overconsumption and premature exhaustion of the unstaking limiter; underconsumption is possible only if a conversion can make underlying exceed the counted shares.
- **Kill test:** queue the same economic withdrawal before and after a non-1:1 scaling/slashing state and compare actual receivable ETH with consumed capacity.
- **Triage risk:** executor-only and potentially classified as an EigenLayer-originating condition.

## 6. Selector-only EigenPod call authorization

- **Code:** `EtherFiNodesManager.forwardEigenPodCall()`.
- **Hypothesis:** authorization is `(caller, selector)` only. All calldata arguments are forwarded without contract-side restrictions, so a broadly allowed EigenPod selector may permit an unintended receiver, proof target, checkpoint, or other sensitive parameter.
- **Possible impact:** depends entirely on the deployed selector allowlist; potentially withdrawal redirection or state corruption if a powerful selector is enabled.
- **Kill test:** read deployed `allowedForwardedEigenpodCalls` events/storage, enumerate enabled selectors, and fuzz their sensitive arguments.
- **Triage risk:** requires an EigenPod-operations role unless a public caller is actually allowlisted.

## 7. DepositAdapter double-rounding residue

- **Code:** `DepositAdapter._wrapAndReturn()`.
- **Hypothesis:** newly minted eETH shares are converted to an eETH amount, then `weETH.wrap(amount)` converts the amount back to shares. Two floor operations can leave eETH shares in the adapter rather than returning all minted value to the depositor.
- **Possible impact:** systematic user loss and sweepable adapter residue if the discrepancy grows with exchange-rate extremes or repeated deposits.
- **Kill test:** fuzz share price and deposit size across all adapter paths; measure `minted shares - wrapped shares` and adapter residue.
- **Triage risk:** likely bounded to 1–2 wei and intended sweep behavior unless the error scales.

## Suggested order

Run only the kill tests for **1, 3, 2, and 4**, in that order. Drop any lead immediately if the required state cannot occur under deployed configuration or if impact requires a malicious privileged role. Leads 5–7 are useful only as quick boundary fuzz targets.
