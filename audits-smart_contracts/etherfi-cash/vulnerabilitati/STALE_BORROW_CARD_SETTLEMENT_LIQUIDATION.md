# Stale borrow intent can consume a card authorization's health buffer and expose the Safe to immediate liquidation

## Status

Promising candidate. The cross-flow path is reproduced against the real Aave v4 test instance.

Suggested severity: **High**, with a possible **Critical** impact argument if the program classifies forced liquidation and the liquidator's collateral bonus as direct theft of user funds.

> **Final bounty assessment: known/accepted behavior under the applicable trust and
> security assumptions, rather than a novel High or Critical submission.** The PoC is
> useful as an independent reproduction of the interaction between delayed borrow
> authorization, card settlement, and liquidation. However, the relevant settlement
> behavior was already documented in the Certora material and the protocol intentionally
> permits an already-authorized card settlement to use the raw liquidation boundary.
> The severity above describes the technical impact if that behavior were treated as a
> violated security invariant; it does not represent the final bounty-validity verdict.

This is stronger than the standalone “borrow signature has no deadline” or “Cash/Aave prices can drift” observations. The current production borrow assets use equivalent Cash and Aave price roots, so oracle drift is not needed.

## Summary

An EtherFi Cash borrow intent binds:

~~~
BORROW_METHOD, chainId, safe, nonce, token, amountInUsd
~~~

It does not bind a deadline, the CashModule address, the lending-engine state, a position snapshot, or an outstanding card authorization.

Any relayer can therefore retain a still-current owner-quorum borrow signature and choose when to execute it. The borrow page sends the borrowed token to the Safe and immediately supplies it back to Aave as collateral. For launch USDC, that supply restores 95% of the borrowing power consumed by the new USDC debt.

Card authorization and settlement are asynchronous. CashLens.canSpend authorizes against the configured 1.05 health-factor floor, but the later CashModule.spend deliberately settles an already-authorized card payment against Aave's raw 1.00 boundary. No on-chain reservation prevents another authorized operation from consuming the five-percent buffer between those two checks.

A relayer can execute a withheld borrow between card authorization and settlement. Auto-supply restores enough capacity for the old card authorization to remain executable, but the combined debt can place the Safe at approximately HF 1.00. As soon as debt interest advances, the Safe becomes liquidatable. A permissionless liquidator can repay USDC and seize the Safe's collateral with a liquidation bonus.

No EtherFi trusted role must act maliciously: the EtherFi wallet performs the card settlement it was already expected to perform. The attacker only needs the valid borrow payload and permissionless access to Aave liquidation.

## Affected code

- src/libraries/CashVerificationLib.sol:161-163
  - The borrow digest has no deadline or position/card-authorization state.
- src/modules/cash/CashModuleCore.sol:598-600
  - Any caller can submit the signed borrow; the Safe nonce is consumed only when execution succeeds.
- src/modules/cash/CashLendLib.sol:410-423
  - The current price converts USD to token units, the gateway borrows, proceeds are supplied back, and only the final 1.05 floor is checked.
- src/modules/cash/CashLendLib.sol:682-721
  - Card settlement uses rawBorrowCapacity, not the configured health-factor floor.
- src/libraries/LendSourcingLib.sol:97-124
  - Card authorization uses the buffered borrowCapacity.
- src/modules/lend-gateway/LendGateway.sol:675-698
  - The authorization quote uses the configured floor while settlement uses the raw 1.00 bound.

## Root cause

This is an authorization-state TOCTOU across two independently authorized flows:

1. a borrow signature remains valid until its nonce is consumed;
2. a card authorization is calculated off-chain from the current buffered capacity;
3. neither authorization reserves capacity or invalidates the other;
4. borrow auto-supply restores most of the capacity consumed by the borrow;
5. card settlement intentionally ignores the configured buffer and only requires Aave HF >= 1.

The missing borrow deadline makes the race attacker-selectable for as long as the nonce remains current. Adding a deadline reduces the window but does not by itself serialize a borrow against a card authorization already in flight.

## Attack path

1. The Safe supplies volatile collateral such as weETH to the EtherFi Aave v4 Spoke.
2. The Safe owners sign a large USDC borrow-page intent. The payload has no expiry.
3. The transaction is not immediately executed. Its Safe nonce remains current.
4. Later, a card payment is authorized while CashLens.canSpend observes sufficient borrowing power at the 1.05 health-factor floor.
5. Before the EtherFi wallet settles that already-authorized card payment, the relayer executes the retained borrow intent.
6. CashModule.borrow opens USDC debt and supplies the proceeds back to the Safe's Aave position.
7. At the production 95% USDC collateral factor, this restores 95% of the capacity consumed by the borrow.
8. A fresh card authorization for the old amount would now fail the 1.05 buffered check, but the already-authorized settlement is intentionally allowed to use rawBorrowCapacity.
9. The EtherFi wallet settles the card payment. The combined position lands at approximately HF 1.00.
10. Debt interest advances the position below HF 1.
11. The attacker calls Aave v4 liquidationCall, repays USDC debt, and receives the Safe's weETH collateral with the liquidation incentive.

## Proof of concept

The regression PoC is:

~~~
test/safe/modules/cash/lend/MinHealthFactor.t.sol
test_staleBorrowSandwichesCardSpendIntoLiquidation
~~~

It uses:

- the real Aave v4 test deployment, not MockLendGateway;
- the production launch USDC collateral factor of 95%;
- a one-day delay between signature creation and borrow execution;
- the exact same card txId and amount passing CashLens.canSpend before the borrow;
- that authorization failing a fresh buffered check after the borrow while settlement still succeeds;
- the raw execution capacity after the stale borrow;
- one second of post-settlement interest;
- a permissionless Aave liquidation that transfers weETH collateral to the liquidator.

Command:

~~~bash
FOUNDRY_PROFILE=lend TEST_CHAIN=10 forge test \
  --match-path test/safe/modules/cash/lend/MinHealthFactor.t.sol \
  --match-test test_staleBorrowSandwichesCardSpendIntoLiquidation -vv
~~~

Result:

~~~
[PASS] test_staleBorrowSandwichesCardSpendIntoLiquidation()
1 passed; 0 failed
~~~

## Why the standalone oracle theory is not the impact

Only USDC and WETH are borrowable in the launch payload.

The pinned Aave WETH adapter and Cash both read the same Optimism ETH/USD Chainlink aggregator. The pinned Aave USDC adapter and Cash both read the same USDC/USD aggregator and apply the same strict inside-1% snap to one dollar. A live read of the pinned Aave feeds confirmed those sources and transformations.

The planned Aave USDC cap adapter would replace the snap with a raw price capped at $1.04. Even then, the relevant normal-band difference is below 1% and does not independently support High severity.

The liquidation path instead arises from overlapping capacity authorizations and raw-bound card settlement.

## Severity

### Impact

The final state is liquidatable and the PoC demonstrates an untrusted liquidator receiving the Safe's collateral. The user suffers forced position closure, interest, and the liquidation incentive transferred to the liquidator. The loss scales with the Safe's collateral and the signed/card amounts.

The scope lists “direct theft of any user funds” as Critical. A conservative submission can use High because the direct loss is the liquidation penalty rather than the gross collateral transferred, and because the attack has significant prerequisites.

### Required conditions

- The attacker obtains a valid owner-quorum borrow signature.
- Its Safe nonce remains current; a confirmed nonce cancellation defeats it.
- The signed borrow is large enough to consume the relevant capacity buffer.
- A material card payment is authorized before the borrow executes.
- The borrow executes after authorization but before card settlement.
- The card settlement is large enough to leave the combined position near HF 1.

## Rejection and invalidation risks

1. **Owners authorized the borrow.** Reviewers may argue that executing an unexpired, nonce-valid owner-quorum instruction is intended. The response is that there is no signed expiry or state bound, and the security issue is the adversarial composition with a separately authorized card payment.
2. **The card payment is also user-originated.** Both nominal amounts were authorized. The unexpected effect is that each authorization was admitted against the same health buffer and the protocol permits both to settle without reserving that buffer.
3. **The attacker cannot call spend.** This is true. The attack requires a legitimate card settlement; it does not assume the EtherFi wallet is malicious.
4. **The attacker must time an off-chain authorization window.** This lowers likelihood. The protocol explicitly supports asynchronous “already-authorized” settlement, so the window is part of the intended flow, but its practical visibility and duration should be documented.
5. **Users can cancel the Safe nonce.** Cancellation requires the owner quorum and races the retained borrow. It is effective once confirmed, but it does not protect users who do not know the payload is being withheld.
6. **Near-maximum amounts are required for immediate liquidation.** Smaller combinations retain more health margin. Because the signature has no deadline, an attacker can wait for collateral prices and a card amount that make the combination fit, but this remains a meaningful exploitability constraint.
7. **The test interest model may differ from production utilization.** The exact time to cross HF 1 depends on live borrow/supply rates. The structural end state is at the raw boundary; any positive net debt accrual or adverse collateral movement can make it liquidatable.

## Recommendations

1. Add deadline, address(this), and preferably a maximum token amount to the borrow signature.
2. Introduce an on-chain position/authorization epoch. Increment it whenever borrow-page debt, collateral, mode, migration, withdrawal, or another capacity-changing action succeeds.
3. Bind card authorization to that epoch, or reserve its weighted debt capacity on-chain until settlement/cancellation.
4. If the epoch changed, do not settle against the raw boundary using the stale authorization. Require reauthorization or enough current capacity at the configured floor.
5. Add invariant tests covering card authorization -> borrow -> settlement and every other capacity-changing permutation.
