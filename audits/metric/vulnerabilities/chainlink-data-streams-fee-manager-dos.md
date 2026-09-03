# Chainlink Data Streams reports cannot be ingested on fee-charging networks

## Severity

Medium

`ChainlinkOracle` calls the Chainlink `VerifierProxy` without performing the FeeManager payment flow. On Base, where a FeeManager is deployed and the repository config selects LINK as the fee token, a normal fee-charging report therefore reverts before it can be stored. The oracle has no ERC-20 approval or arbitrary-call recovery method, so funding the deployed contract with LINK does not fix it.

This breaks the complete Chainlink-backed pricing path. Pools using the affected oracle cannot receive new observations; once the last stored observation exceeds the provider's staleness limit, every swap fails. Liquidity removal remains available, so Medium is more defensible than High.

## Affected code

- `smart-contracts-poc/contracts/oracles/providers/ChainlinkOracle.sol:29`
- `smart-contracts-poc/contracts/oracles/providers/ChainlinkOracle.sol:81-83`
- `smart-contracts-poc/contracts/oracles/providers/OracleBase.sol:294-302`
- `smart-contracts-poc/script/config/networks.json:509-512`

## Root cause

The integration hardcodes a zero native verification fee and passes only the configured fee-token address to `verify`:

```solidity
uint256 internal constant VERIFICATION_FEE = 0 wei;

function _verifyReport(bytes calldata fullReport)
    internal
    virtual
    returns (bytes memory reportData)
{
    return verifierProxy.verify{value: VERIFICATION_FEE}(
        fullReport,
        abi.encode(feeToken)
    );
}
```

On a network with a Chainlink FeeManager, passing `abi.encode(feeToken)` selects token billing. The expected integration flow is:

1. Read `VerifierProxy.s_feeManager()`.
2. Ask the FeeManager for the report fee with `getFeeAndReward(...)`.
3. Read the FeeManager's RewardManager.
4. Approve that RewardManager to pull the quoted LINK amount.
5. Call `VerifierProxy.verify(...)` with the encoded LINK address.

`ChainlinkOracle` performs only step 5.

The official Chainlink integration guide states that Base has a FeeManager and requires token payment. Its example queries the fee, approves the RewardManager, and then verifies the report:

- [Chainlink Data Streams on-chain verification guide](https://docs.chain.link/data-streams/tutorials/evm-onchain-report-verification)
- [Chainlink LINK token addresses](https://docs.chain.link/resources/link-token-contracts)

The Base deployment configuration makes the failure concrete:

```json
"chainlink": {
  "verifierProxy": "0xDE1A28D87Afd0f546505B28AB50410A5c3a7387a",
  "feeToken": "0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196"
}
```

`0x88Fb...196` is the official Base mainnet LINK token.

## Why funding does not help

Fee collection is performed with an ERC-20 pull from the subscriber. A LINK balance is therefore insufficient without an allowance from `ChainlinkOracle` to the Chainlink RewardManager.

The contract:

- imports no ERC-20 interface;
- never calls `approve`;
- has no owner function for approving or transferring fee tokens;
- has immutable `verifierProxy` and `feeToken` addresses;
- inherits a fallback that reverts with `NotImplemented`.

Consequently, the oracle admin cannot repair the allowance after deployment. The affected instance must be replaced or the integration upgraded.

## Attack/failure flow

No malicious oracle report is required:

1. A correct and timely DON-signed Data Streams report is available.
2. Any updater calls `ChainlinkOracle.updateReport(report)`.
3. `_verifyReport` invokes `VerifierProxy.verify(report, abi.encode(LINK))`.
4. The FeeManager calculates a nonzero LINK fee.
5. The RewardManager attempts to pull LINK from `ChainlinkOracle`.
6. The pull fails because the allowance is zero, so report ingestion reverts.
7. No later Chainlink observation can be stored through the normal fee-charging path.
8. Existing observations eventually fail `MAX_TIME_DELTA` / `MAX_REF_STALENESS`, causing all dependent pool swaps to revert.

The issue is systemic for every pool sharing the oracle, rather than limited to a maliciously configured pool or custom extension.

## Proof of concept

The PoC is in:

```text
smart-contracts-poc/test/oracles/ChainlinkOracleFeeManager.audit.t.sol
```

It models the documented FeeManager/RewardManager pull flow and demonstrates both that:

- a fully LINK-funded oracle still cannot verify because its allowance is zero; and
- the admin cannot repair the allowance through the reverting fallback.

Run:

```bash
cd smart-contracts-poc
forge test --match-path test/oracles/ChainlinkOracleFeeManager.audit.t.sol -vv
```

Observed result:

```text
[PASS] test_fundedOracleCannotPayFeeManagerBecauseRewardManagerHasNoAllowance()
[PASS] test_adminCannotRepairAllowanceThroughOracleFallback()

fee-token balance already held by oracle: 100000000000000000000
allowance granted to Chainlink RewardManager: 0
```

## Scope and README assumptions

This finding does not require an incorrect, delayed, or stale off-chain report. A correct report reaches the on-chain adapter and fails solely because the adapter cannot satisfy the verifier's payment interface.

The only material caveat is a subscriber-specific 100% fee discount. No such waiver is guaranteed by the repository or deployment scripts, and the standard Base integration explicitly requires FeeManager payment. A production oracle cannot rely on an undocumented full discount as its only executable path.

## Recommendation

Implement the network-aware FeeManager flow used by Chainlink's reference integration:

1. Query `s_feeManager()` on the verifier proxy.
2. If it is nonzero, quote the exact fee with `getFeeAndReward`.
3. Approve only the required amount to the returned RewardManager.
4. Call `verify` with the selected fee-token payload.
5. If no FeeManager exists, call `verify` with an empty parameter payload.

Also add:

- an admin method to withdraw stranded fee tokens;
- an explicit funding/allowance health view;
- integration tests using a fee-charging verifier, not only a mock that accepts a fixed native value;
- replay-resistance or caller-funded billing so repeated verification of already stored reports cannot consume the oracle's operational reserve.
