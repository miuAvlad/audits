# Vulnerability Research

I am expanding my vulnerability research to more complex codebases, starting with **Libreswan**.
For the moment I am not going to include the full notes and explain my methodology similar
my smart contract projects.

## Disclosure Policy

Findings are published after remediation is public or disclosure is explicitly
authorized. Bounded reproduction material is included when it can be shared
safely.

## Current Status

| Project | Confirmed Findings | Published Reports | CVEs |
| --- | ---: | ---: | --- |
| Libreswan | 4 | 3 | [CVE-2026-94453](https://libreswan.org/security/CVE-2026-94453/) |

## Finding Status

| # | Finding | Disclosure | Remediation status | References |
| ---: | --- | --- | --- | --- |
| 1 | [IKEv2 use-after-free in an IKE-over-TCP endpoint](libreswan/IKE_OVER_TCP_ENDPOINT_UAF_CVE-2026-94453.md) | Public report and [PoC](libreswan/ikev_over_tcp_poc/README.md) | Patched; fixed in Libreswan 5.3.3 and 5.4.1 | [CVE-2026-94453 advisory](https://libreswan.org/security/CVE-2026-94453/) |
| 2 | [IKEv2 IPSECKEY DNS cleanup use-after-free](libreswan/IPSECKEY_DNS_UAF_REPORT.md) | Public report and [PoC](libreswan/ipsec_dns_poc/README.md) | Patched on `main` | [Issue #3071](https://github.com/libreswan/libreswan/issues/3071), [fix](https://github.com/libreswan/libreswan/commit/b04c3a27f7a047260d8fa99c460cc49f345da9c6) |
| 3 | [IKEv2 incomplete fragment-queue resource retention](libreswan/IKE_v2_fragmentation.md) | Public report and [bounded PoC](libreswan/ikev2_fragmentation_poc/README.md) | Fix planned according to the maintainer response | [Issue #3079](https://github.com/libreswan/libreswan/issues/3079) |
| 4 | EAP-TLS identity misbinding authorization bypass | Report forthcoming | Confirmed; patch received from the maintainers | — |
