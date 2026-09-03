# [M] Reserve-socialization haircuts can reopen `dailyDebtIncreaseLimitLeft` too early because excess cap reduction is forgotten

## Summary
When a reserve-socialization haircut reduces the lender base, `V3Vault` rescales the daily debt cap to the post-haircut lender base. However, if the cap reduction is larger than the remaining `dailyDebtIncreaseLimitLeft`, the code simply clamps the remaining headroom to `0` and discards the excess reduction.

Later in the same day, liquidations and repayments add fresh headroom back to `dailyDebtIncreaseLimitLeft`, even though the protocol should still remain over the reduced post-haircut budget. This reopens borrow capacity too early and bypasses the intended daily debt circuit breaker in exactly the stressed state where it matters most.

## Vulnerability Details
During reserve socialization, `_handleReserveLiquidation()`:
1. computes the pre-haircut daily debt cap;
2. applies the lender haircut by reducing `lastLendExchangeRateX96`;
3. computes the post-haircut daily debt cap;
4. reduces `dailyDebtIncreaseLimitLeft` by `capReduction = preHaircutCap - postHaircutCap`.

The issue is the clamp:
- if `capReduction >= dailyDebtIncreaseLimitLeft`, the contract sets `dailyDebtIncreaseLimitLeft = 0`;
- but it does not store the remaining deficit `capReduction - oldLimitLeft` anywhere.

That means the protocol forgets that, relative to the new lower post-haircut budget, it is still effectively overdrawn.

Later, in the same day:
- `liquidate()` increases `dailyDebtIncreaseLimitLeft` by `liquidatorCost`;
- `repay()` increases `dailyDebtIncreaseLimitLeft` by repaid assets.

Because the forgotten deficit is not repaid first, this newly credited headroom can be consumed immediately by `borrow()`, reopening debt issuance even though the haircut was supposed to tighten the daily cap.

## Why This Matters
This is not just an accounting quirk.

The sponsor explicitly documents the daily debt increase limit as a critical protocol safety rail and states that bypasses are unacceptable. The bug lets borrowers regain intraday issuance capacity after the protocol has already suffered a reserve shortfall and reduced the lender base.

In other words, the circuit breaker weakens exactly when the system is under stress.

## Impact
The bug allows new debt to be issued in the same day after a reserve-socialization haircut has already reduced the daily debt budget.

While this does not guarantee an immediate second loss by itself, it defeats a documented risk control and allows the protocol to re-expand debt exposure too early after a shortfall event. If market stress continues, this can amplify subsequent bad debt and lender losses.

## Affected Code
- `src/V3Vault.sol:613` - `borrow()` consumes `dailyDebtIncreaseLimitLeft` directly.
- `src/V3Vault.sol:616` - the remaining headroom is decremented on borrow.
- `src/V3Vault.sol:767` - `liquidate()` credits `liquidatorCost` back into `dailyDebtIncreaseLimitLeft`.
- `src/V3Vault.sol:1039` - `repay()` credits repaid assets back into `dailyDebtIncreaseLimitLeft`.
- `src/V3Vault.sol:1200` - `_handleReserveLiquidation()` handles reserve socialization.
- `src/V3Vault.sol:1212` - computes the pre-haircut daily debt cap.
- `src/V3Vault.sol:1221` - computes the post-haircut daily debt cap.
- `src/V3Vault.sol:1227` - derives `capReduction`.
- `src/V3Vault.sol:1228` - clamps `dailyDebtIncreaseLimitLeft` to `0` and discards the excess deficit.
- `docs/agents/risk-and-acceptability.md:75` - daily debt increase limit is documented as a critical safety rail.
- `docs/agents/risk-and-acceptability.md:78` - bypasses are explicitly unacceptable.

## Proof of Concept
PoC file:
- `test/integration/uniswap/V3VaultDailyDebtCapBypass.t.sol`

The PoC:
1. deposits lender liquidity and configures the daily debt cap to be dynamic with no minimum floor;
2. consumes almost the entire daily debt headroom;
3. forces several victim positions into deep shortfall so liquidations trigger reserve socialization haircuts;
4. verifies that, for each liquidation, the haircut's `capReduction` is larger than the remaining daily headroom;
5. observes that the clamp forgets the excess deficit and `liquidatorCost` reopens positive `dailyDebtIncreaseLimitLeft`;
6. immediately borrows against a separate attacker position using that reopened headroom.

This demonstrates that debt issuance can resume intraday after the haircut, despite the post-haircut cap having already been exceeded in substance.

## Attack Path
1. Consume most of the daily debt budget.
2. Trigger or wait for a reserve-shortfall liquidation that socializes losses to lenders.
3. Let `_handleReserveLiquidation()` clamp `dailyDebtIncreaseLimitLeft` to `0` while discarding the excess reduction.
4. Use a subsequent liquidation or repayment to re-credit `dailyDebtIncreaseLimitLeft`.
5. Borrow again in the same day using the newly reopened headroom.

## Recommendation
Track the forgotten reduction explicitly.

A simple fix is to introduce a persistent deficit variable, for example `dailyDebtIncreaseDeficit`:
1. on haircut, if `capReduction > dailyDebtIncreaseLimitLeft`, set `dailyDebtIncreaseDeficit += capReduction - dailyDebtIncreaseLimitLeft` and then set `dailyDebtIncreaseLimitLeft = 0`;
2. on `repay()` and `liquidate()`, apply new credits to the deficit first;
3. only any remaining surplus should increase `dailyDebtIncreaseLimitLeft`.

Invariant test to add:
- after any haircut, same-day debt issuance should remain constrained by the post-haircut daily cap until any excess previously-used budget has been fully absorbed.
