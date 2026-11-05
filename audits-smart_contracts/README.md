# Smart Contract Security Research

**13 confirmed contest findings: 6 High and 7 Medium.** Public results span Sherlock, Cantina, and Code4rena. My [Sherlock Watson profile](https://audits.sherlock.xyz/watson/taticuvostru) aggregates the contest record.

## Selected findings

| Project | Result | Finding |
| --- | --- | --- |
| GTE Perps and Launchpad | #13 · High | [Reward shares can reach zero after unlocking, bricking a launchpad pair](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad/submissions/S-644) |
| GTE Spot CLOB and Router | #21 · High | [Order-list corruption when `prevOrderId` is not persisted](https://code4rena.com/audits/2025-07-gte-spot-clob-and-router/submissions/S-332) |
| Super DCA Liquidity Network | #52 · High | [Reward-accrual denial of service and donation sniping](https://audits.sherlock.xyz/contests/1171/voting/661) |
| Metric | #25 · Medium | [Pyth observations bypass the velocity-extension cap](https://audits.sherlock.xyz/contests/1279/voting/2716) |

## Full contest record

The three Revert Finance findings were confirmed through Cantina across two competitions; direct report links are unavailable. Rankings shown below are contest placements, not finding ranks.

| Contest | Place | Severity | Finding |
| --- | ---: | :---: | --- |
| [Metric](https://audits.sherlock.xyz/contests/1279) | #25 | Medium | [Users can bypass velocity extension cap using multiple valid Pyth observations](https://audits.sherlock.xyz/contests/1279/voting/2716) |
| [Metric](https://audits.sherlock.xyz/contests/1279) | #25 | Medium | [Eight-decimal oracle normalization can make the pool trade below a fresh signed price](https://audits.sherlock.xyz/contests/1279/voting/2743) |
| [Revert Finance](https://cantina.xyz/competitions/efb6f308-f13b-4110-aff8-0d67181608dd) | #14 | Medium | Confirmed finding; direct report link unavailable |
| [Revert Finance — StableSwap Hooks](https://cantina.xyz/code/e55ee7b9-6c99-42f8-8338-39f3dd134ef3/overview) | — | High | Confirmed finding; direct report link unavailable |
| [Revert Finance — StableSwap Hooks](https://cantina.xyz/code/e55ee7b9-6c99-42f8-8338-39f3dd134ef3/overview) | — | Medium | Confirmed finding; direct report link unavailable |
| [Super DCA Liquidity Network](https://audits.sherlock.xyz/contests/1171) | #52 | High | [Reward Accrual DoS and donation sniping through stake/unstake timing](https://audits.sherlock.xyz/contests/1171/voting/661) |
| [GTE Perps and Launchpad](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad) | #13 | High | [Reward shares can reach zero after unlocking and brick `GTELaunchpadV2Pair`](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad/submissions/S-644) |
| [GTE Perps and Launchpad](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad) | #13 | High | [Computed CREATE2 pair address differs from the pair deployed by the factory](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad/submissions/S-646) |
| [GTE Perps and Launchpad](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad) | #13 | High | [Backstop bid side can be frozen by the tick-size constraint](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad/submissions/S-735) |
| [GTE Perps and Launchpad](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad) | #13 | Medium | [Quote rounding permits underpriced LaunchToken purchases and compounding losses](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad/submissions/S-1576) |
| [GTE Perps and Launchpad](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad) | #13 | Medium | [Launchpad slippage is not properly enforced during token graduation](https://code4rena.com/audits/2025-08-gte-perps-and-launchpad/submissions/S-640) |
| [GTE Spot CLOB and Router](https://code4rena.com/audits/2025-07-gte-spot-clob-and-router) | #21 | High | [Order double-linked list breaks because `prevOrderId` is not persisted](https://code4rena.com/audits/2025-07-gte-spot-clob-and-router/submissions/S-332) |
| [Mellow Flexible Vaults](https://audits.sherlock.xyz/contests/964) | #43 | Medium | [Missing negation in a whitelist check causes an unjustified revert](https://audits.sherlock.xyz/contests/964/voting/52) |

## Independent research

- [Metric workspace](metric/README.md): oracle and pool-behavior reports, Foundry and Echidna tests, and submission triage. These are research artifacts; the confirmed contest findings are identified above.
- [EtherFi research](etherfi/): protocol-flow analysis, reproductions, and candidate issues.
- [EtherFi Cash research](etherfi-cash/): accounting, liquidation, bridge, and oracle investigations with tests and impact analysis.
- [Earlier Sei review](findings/old-sei-findings.md): Go protocol analysis.

Candidate reports and working notes may depend on privileged configuration, user behavior, or assumptions outside a bounty's threat model. Their own impact and invalidation sections provide the relevant limits; they are not part of the confirmed contest count.

## Research process

I map contracts, roles, and shared state; derive invariants from the implementation; then test concrete hypotheses with targeted reproductions, Foundry fuzz or invariant tests, and Echidna. I check reachability and practical impact before treating a candidate as a finding. AI assists with navigation and test scaffolding; I validate the result against code and observed behavior.
