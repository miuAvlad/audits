# Cash v3 Solidity test archive

This directory preserves the audit tests separately from the protocol source tree.

## Source provenance

- Repository: `https://github.com/etherfi-protocol/cash-v3`
- Branch at archival time: `master`
- Commit at archival time: `804ea097915ec7638de88f9f7f48afb39774a76a`
- Archive layout: `repository-overlay/` mirrors the original repository paths.

The Solidity files are complete snapshots, not diffs. They still import contracts and test helpers from the original repository, so this directory alone is not a standalone Foundry project.

## Preserved tests

- `test/audit/StargatePendingTopUpRetryForkPoC.t.sol`: production pending Stargate top-up retry PoC.
- `test/audit/echidna/PendingWithdrawalCoverage.echidna.sol`: isolated pending-withdrawal token-state campaign.
- `test/price-provider/PriceProviderV1ScrollPausedRate.t.sol`: paused-accountant rate investigation.
- `test/price-provider/PriceProviderV1ScrollStaleness.t.sol`: stale-accountant rate investigation.
- `test/safe/modules/cash/lend/CashFlowsInvariant.t.sol`: expanded stateful Cash/Aave v4 invariant campaign.
- `test/safe/modules/cash/lend/GhostCollateralOracleLock.t.sol`: stale zero-balance reserve/oracle lock PoC.
- `test/safe/modules/cash/lend/MinHealthFactor.t.sol`: complete modified suite containing the stale-borrow/card-settlement race test.
- `echidna-pending-withdrawal.yaml`: Echidna campaign configuration.

## Restore into a fresh clone

From a directory containing this archived `my-audit` folder:

```bash
git clone https://github.com/etherfi-protocol/cash-v3.git cash-v3
cd cash-v3
git checkout 804ea097915ec7638de88f9f7f48afb39774a76a
cp -a /path/to/etherfi-cash/solidity-tests/repository-overlay/. .
```

Run an individual Foundry test with the environment required by that test, for example:

```bash
forge test --match-path test/safe/modules/cash/lend/GhostCollateralOracleLock.t.sol -vvv
```

Fork-based suites require a suitable RPC endpoint. The isolated Echidna campaign does not:

```bash
echidna test/audit/echidna/PendingWithdrawalCoverage.echidna.sol \
  --contract PendingWithdrawalCoverageEchidna \
  --config echidna-pending-withdrawal.yaml
```

Before publishing, scan the entire retained `my-audit` directory for RPC credentials, API keys, private keys, personal paths, and draft statements that are not ready for disclosure.
