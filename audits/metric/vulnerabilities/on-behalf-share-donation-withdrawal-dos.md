# Permissionless sub-minimum share donations can indefinitely prevent LPs from closing positions

## Severity

**Low**

## Summary

`MetricOmmPool.addLiquidity()` lets the payer assign newly minted shares to any `owner`, and the production `MetricOmmPoolLiquidityAdder` deliberately exposes this sponsored-deposit flow. For an existing position, an attacker may add fewer than `minimalMintableLiquidity` shares because the add-side check validates only the owner's resulting total balance.

An LP withdrawal specifies an exact number of shares. If the attacker front-runs a full withdrawal by donating `d` shares where `0 < d < minimalMintableLiquidity`, the victim's burn would leave `d` shares. The remove-side anti-dust check rejects exactly that state and reverts the entire withdrawal.

After the victim refreshes their balance and retries, the attacker can donate another share and invalidate the new exact amount again. A position holding exactly the configured minimum cannot make a smaller withdrawal, so its entire principal remains exposed to this permissionless censorship. A larger position can withdraw down to the minimum, but its final minimum-sized tranche remains indefinitely griefable.

## Root Cause

The core pool accepts an arbitrary position owner without owner authorization:

- `metric-core/contracts/MetricOmmPool.sol:182-194`

`LiquidityLib.addLiquidity()` credits the payer-selected `(owner, salt, bin)` key. For existing positions, a one-share addition passes whenever the resulting total remains above the minimum:

- `metric-core/contracts/libraries/LiquidityLib.sol:72-78`

Removal, however, rejects every nonzero remainder below the minimum:

- `metric-core/contracts/libraries/LiquidityLib.sol:192-201`

The production helper confirms that arbitrary-owner deposits are an intended, reachable integration path: `msg.sender` pays while `owner` receives the shares:

- `metric-periphery/contracts/MetricOmmPoolLiquidityAdder.sol:51-67`

There is no `removeAllLiquidity` sentinel or remover that resolves the owner's live share balance atomically. Core removal also requires `msg.sender == owner`, so an EOA cannot use an ordinary helper contract to read the updated balance and close the position in one call.

## Attack Flow

Assume `minimalMintableLiquidity = 1,000`, which is the repository's default test configuration.

1. Alice owns `U` shares in `(pool, Alice, salt, bin)` and submits a transaction removing all `U` shares.
2. The attacker observes it and first calls `addLiquidity(Alice, salt, ...)` for one share, paying the proportional token cost.
3. Alice's transaction calculates `newUserShares = U + 1 - U = 1`.
4. Since `0 < 1 < 1,000`, `MinimalLiquidity(1, 1_000)` reverts the complete withdrawal.
5. Alice refreshes the position and submits a burn of `U + 1`; the attacker donates one more share before it executes, leaving one share again.
6. The attacker can repeat this for every public retry. Pause levels do not help because liquidity additions and removals intentionally remain available while paused, and the minimum is immutable.

For a multi-bin withdrawal, donating to only one included bin reverts the entire batched call. The victim can split future withdrawals, but each final minimum-sized per-bin position remains targetable.

## Impact

This contradicts the explicit contest invariant that "every LP can withdraw their proportional share." It is not dependent on a stale oracle, malicious provider, trusted admin, custom extension, nonstandard token, or invalid pool deployment.

The griefing cost is approximately one share's pro-rata value. With a minimum of 1,000 shares, one donation costs roughly 0.1% of the minimum position's value per invalidated attempt. The real-factory PoC uses two standard 18-decimal ERC-20s, a 1:1 oracle, and a factory-accepted density:

- minimum position: `1.0` token;
- one-share donation: `0.001` token;
- result: the victim's full withdrawal reverts.

The same share geometry can represent materially valuable positions because shares are an arbitrary accounting unit and the factory permits the demonstrated density. The attacker does give the donated value to the victim and pays gas, so this is a targeted liveness/griefing attack rather than theft. However, the attacker can maintain it indefinitely in the public mempool, and an exactly-minimum LP has no protocol-level exit path.

`minimalMintableLiquidity == 1` removes the below-minimum integer remainder and therefore this specific revert. That setting substantially weakens the anti-dust mechanism that the minimum was introduced to provide. The repository's standard value is 1,000, and every meaningful value above one exposes the same root cause, with attack cost becoming cheaper relative to locked value as the minimum increases.

## Proof of Concept

Three passing tests cover the core mechanism, production helper, and material factory configuration:

- `metric-core/test/OnBehalfShareDonation.audit.t.sol`
  - repeats two donation/retry cycles;
  - proves each donation costs one raw unit in the standard fixture;
  - demonstrates that a larger position can only bound the attack by leaving the minimum behind.
- `metric-periphery/test/ShareDonationWithdrawalDoS.audit.t.sol`
  - creates an EOA-owned position through the real `MetricOmmPoolLiquidityAdder`;
  - uses the same production helper from a different payer to invalidate the EOA's withdrawal.
- `metric-core/test/OnBehalfShareDonation.material.audit.t.sol`
  - deploys the pool through the real `MetricOmmPoolFactory`;
  - locks a one-token minimum position with a `0.001`-token share donation.

Run:

```bash
cd metric-core
forge test --match-path test/OnBehalfShareDonation.audit.t.sol -vv
forge test --match-path test/OnBehalfShareDonation.material.audit.t.sol -vv

cd ../metric-periphery
FOUNDRY_OFFLINE=true forge test \
  --match-path test/ShareDonationWithdrawalDoS.audit.t.sol \
  --skip ProviderOwnershipStaleUpdaterPoolPoC \
  -vv
```

Observed material-case logs:

```text
minimum position blocked: 1.000000000000000000
cost to invalidate one withdrawal: 0.001000000000000000
```

## Recommendation

Provide an owner-authorized, execution-time full-exit path. For example, add a dedicated `removeAllLiquidity` entry point or an explicit sentinel that resolves each position's current share balance inside the pool transaction.

Additionally, prevent unauthorized sub-minimum top-ups. Options include requiring an owner permit/operator approval for on-behalf additions, requiring each third-party share increment to be at least `minimalMintableLiquidity`, or allowing arbitrary sponsored deposits only through an owner-approved nonce.

The fix should preserve sponsored deposits while ensuring an external payer cannot make a signed full-withdrawal amount stale by an amount that the anti-dust check itself forbids the owner from leaving behind.
