# Security Research & Audit Portfolio

I review smart contracts and systems software, trace failures across component boundaries, and build reproducible proof of concepts. My public work includes **13 confirmed contest findings (6 High, 7 Medium)** and **three Libreswan vulnerability reports**, including a [vendor-published CVE](https://libreswan.org/security/CVE-2026-94453/).

## Start here

| Work | Evidence | What it shows |
| --- | --- | --- |
| [Smart contract audit results](audits-smart_contracts/README.md) | [Sherlock Watson profile](https://audits.sherlock.xyz/watson/taticuvostru) · public contest submissions | Accounting, access control, oracle, order-book, and denial-of-service findings across DeFi protocols. |
| [Libreswan: IKE-over-TCP use-after-free](audits-other_codebases/libreswan/IKE_OVER_TCP_ENDPOINT_UAF_CVE-2026-94453.md) | [CVE-2026-94453 advisory](https://libreswan.org/security/CVE-2026-94453/) · [PoC](audits-other_codebases/libreswan/ikev_over_tcp_poc/README.md) | Remote, unauthenticated crash of the Pluto IKE daemon; fixed in Libreswan 5.3.3 and 5.4.1. |
| [Libreswan: IPSECKEY DNS use-after-free](audits-other_codebases/libreswan/IPSECKEY_DNS_UAF_REPORT.md) | [Upstream fix](https://github.com/libreswan/libreswan/commit/b04c3a27f7a047260d8fa99c460cc49f345da9c6) · [PoC](audits-other_codebases/libreswan/ipsec_dns_poc/README.md) | Pre-authentication crash in DNS callback cleanup under the documented configuration. |
| [Libreswan: IKEv2 fragment retention](audits-other_codebases/libreswan/IKE_v2_fragmentation.md) | [Upstream issue](https://github.com/libreswan/libreswan/issues/3079) · [bounded PoC](audits-other_codebases/libreswan/ikev2_fragmentation_poc/README.md) | Resource retention in incomplete fragment queues, with impact and test limitations documented. |

## Explore the work

- [Smart contracts](audits-smart_contracts/README.md): confirmed contest results, selected technical reports, and research artifacts from EtherFi, EtherFi Cash, and Metric.
- [Systems software](audits-other_codebases/README.md): public Libreswan reports, reproductions, and upstream references.

## How I investigate

I map entry points and trust boundaries, trace shared state across flows, derive security invariants from code, and test attack hypotheses with focused reproductions, fuzzing, or invariant tests. Each report separates observed behavior from assumptions about reachability, impact, and disclosure status.

I use AI-assisted tools for navigation, hypothesis generation, and test scaffolding. I verify conclusions against source code and executable evidence.
