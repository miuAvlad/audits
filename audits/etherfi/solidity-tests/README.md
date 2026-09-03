# EtherFi Solidity test archive

This directory preserves the oracle/rebase audit PoCs separately from the protocol source tree.

## Source provenance

- Repository: `https://github.com/etherfi-protocol/smart-contracts`
- Branch at archival time: `master`
- Commit at archival time: `b4a0968087b178bc346cdf6bee6c0597bf4c42c7`
- `repository-overlay/` mirrors files that originally lived under the repository `test/` directory.
- `pocs/` contains the PoCs that were already maintained under `my-audit/pocs`.

The files are complete snapshots, not diffs. They depend on the original repository contracts, libraries, remappings, and—in the fork variants—an Ethereum RPC endpoint.

## Preserved tests

- `repository-overlay/test/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol`: latest repository-level mainnet-fork version.
- `repository-overlay/test/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.copy.sol`: preserved older working copy; its filename was normalized from `...t copy.sol`.
- `pocs/OraclePositiveRebaseAsyncExitMainnetForkPoC.t.sol`: archived mainnet-fork PoC.
- `pocs/OraclePositiveRebaseAsyncExitMaxPoC.t.sol`: asynchronous-exit maximum-impact model.
- `pocs/OraclePositiveRebaseAsyncExitPoC.t.sol`: asynchronous-exit model.
- `pocs/OraclePositiveRebaseMainnetForkPoC.t.sol`: positive-rebase mainnet-fork PoC.
- `pocs/OraclePositiveRebaseMaxImpactPoC.t.sol`: positive-rebase maximum-impact model.

## Restore into a fresh clone

```bash
git clone https://github.com/etherfi-protocol/smart-contracts.git etherfi-smart-contracts
cd etherfi-smart-contracts
git checkout b4a0968087b178bc346cdf6bee6c0597bf4c42c7
cp -a /path/to/etherfi/solidity-tests/repository-overlay/. .
```

The standalone models under `pocs/` can be copied into the fresh clone's `test/` directory if their imports expect repository-relative paths.

Before publishing, scan the entire retained `my-audit` directory for RPC credentials, API keys, private keys, personal paths, and unfinished claims.
