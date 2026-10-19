# Vulnerability Research

I am expanding my vulnerability research to more complex codebases, starting with **Libreswan**.
For the moment I am not going to include the full notes and explain my methodology similar
my smart contract projects.

## Disclosure Policy

Findings are published after the corresponding patches have been merged into the main branch.
I have not yet decided if I should include the full reproduction scripts.

## Current Status

| Project | Confirmed Findings | Published Reports | CVEs |
| --- | ---: | ---: | --- |
| Libreswan | 4 | 2 | [CVE-2026-94453](https://libreswan.org/security/CVE-2026-94453/) |

## Finding Status

| # | Finding | Disclosure | Remediation status | References |
| ---: | --- | --- | --- | --- |
| 1 | [IKEv2 use-after-free in an IKE-over-TCP endpoint](libreswan/IKE_OVER_TCP_ENDPOINT_UAF_CVE-2026-94453.md) | Public report | Patched; fixed in Libreswan 5.3.3 and 5.4.1 | [CVE-2026-94453 advisory](https://libreswan.org/security/CVE-2026-94453/) |
| 2 | [IKEv2 IPSECKEY DNS cleanup use-after-free](libreswan/IPSECKEY_DNS_UAF_REPORT.md) | Public report | Patched on `main` | [Issue #3071](https://github.com/libreswan/libreswan/issues/3071), [fix](https://github.com/libreswan/libreswan/commit/b04c3a27f7a047260d8fa99c460cc49f345da9c6) |
| 3 | IKEv2 fragment-queue resource exhaustion | Public issue; report forthcoming | Fix planned according to the maintainer response | [Issue #3079](https://github.com/libreswan/libreswan/issues/3079) |
| 4 | EAP-TLS identity misbinding authorization bypass | Report forthcoming | Confirmed; patch received from the maintainers | — |
