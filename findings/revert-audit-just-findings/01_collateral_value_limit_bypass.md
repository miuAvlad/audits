# [H] Per-token collateral exposure limit `collateralValueLimitFactorX32` can be bypassed by lending and withdrawing in the same tx

## Summary

`V3Vault` enforces the per-token collateral exposure limit. This limit is measuerd against the lent assets at the time of the transaction and can be passed by raising the `lentAssets` before borrowing using deposit and lowering it back by withdrawing the lent assets.

This is a direct bypass of a documented critical safety rail.

## Vulnerability Details
Inside`_updateAndCheckCollateral()`.

When debt increases, the vault:
1. adds debt shares to the collateral tokens;
2. computes `lentAssets = totalSupply() * lendExchangeRate`;
3. verifies that the token's debt exposure does not exceed `lentAssets * collateralValueLimitFactorX32 / Q32`.

The check is performed only during debt increase.

A user can execute the following atomic flow through `multicall`:
1. `create()` the NFT-backed loan;
2. `deposit()` a temporary amount of the lending asset, inflating `totalSupply()` and therefore `lentAssets`;
3. `borrow()` while the artificially inflated `lentAssets` makes the exposure check pass;
4. `withdraw()` almost all of the temporary lend back out.

Due to the fact that the protocol does not run the same check on the borrowed token when withdrawing the intended exposure limit is bypassed

## Why The Check Fails
The root cause is the interaction between these two properties:
1. the exposure cap is based on the current lender base, not on a sticky snapshot taken when the debt was opened;
2. the cap is only enforced when debt increases, not when the lender base decreases.

This makes temporary self-lending sufficient to pass the borrow-time check even though the final post-transaction state violates the configured limit.

## Impact
The bypass violates a critical safety rail allowing users to increase exposure on a specific token above the cap intended.
As stated in the `risk-and-acceptability.md` a bypass on this cap is not acceptable.

## Affected Code
- `src/V3Vault.sol:30` - `V3Vault` inherits `Multicall`, enabling the whole sequence atomically.
- `src/V3Vault.sol:938` - `deposit()` mints lend shares and increases the lender base used by the cap.
- `src/V3Vault.sol:598` - `borrow()` refreshes rates and proceeds to the cap check.
- `src/V3Vault.sol:619` - `borrow()` calls `_updateAndCheckCollateral()`.
- `src/V3Vault.sol:1291` - `_updateAndCheckCollateral()` only checks the limit on increasing debt shares.
- `src/V3Vault.sol:1314` - the limit is computed from current `lentAssets`.
- `src/V3Vault.sol:970` - `withdraw()` reduces the lender base without re-validating the exposure cap.
- `docs/agents/risk-and-acceptability.md:76` - the per-token collateral exposure limit is documented as a critical safety rail.
- `docs/agents/risk-and-acceptability.md:78` - the sponsor explicitly states that bypasses are not acceptable.

## Proof of Concept
PoC file:
- `test/integration/uniswap/V3VaultCollateralValueLimitBypass.t.sol`

The PoC performs exactly the atomic sequence above:
1. temporarily lends `1,000 USDC`;
2. borrows `8 USDC` against a DAI-backed loan while the cap is inflated by that temporary lend;
3. withdraws almost the entire temporary lend in the same multicall;
4. confirms that the resulting debt is now greater than the current cap.

The test then verifies that any additional debt increase correctly reverts with `CollateralValueLimit`, proving the final state is indeed above the configured limit.

## Attack Path
1. Configure or target a collateral token whose `collateralValueLimitFactorX32` is tight enough to matter.
2. Deposit a temporary amount of the lending asset to inflate `lentAssets`.
3. Borrow while that temporary lender base makes the exposure check pass.
4. Withdraw the temporary lend in the same transaction.
5. End the transaction with debt still outstanding but now above the intended exposure cap.

## Recommendation
Any state transition that can reduce the denominator of the exposure check should preserve the invariant that outstanding token debt stays within the configured cap.

A robust fix is one of:
1. re-run the collateral exposure limit whenever lender base decreases materially, including on `withdraw()` and `redeem()`;
2. track exposure against a denominator that cannot be temporarily inflated and then immediately removed inside the same atomic flow;
3. explicitly block borrow-and-withdraw cap bypass patterns across the same multicall / transaction.

Invariant test to add:
- after any state-changing call sequence, outstanding token debt must not exceed `currentLentAssets * collateralValueLimitFactorX32 / Q32` for any configured token.
