# Vulnerability Research

I am expanding my vulnerability research to more complex codebases, starting with **Libreswan**.
For the moment I am not going to include the full notes and explain my methodology similar
my smart contract projects.

## Disclosure Policy

Findings are published after the corresponding patches have been merged into the main branch.
I have not yet decided if I should include the full reproduction scripts.

## Current Status

| Project | Confirmed Findings | Published | CVEs |
| --- | ---: | ---: | --- |
| Libreswan | 3 | 2 | [CVE-2026-94453](https://libreswan.org/security/CVE-2026-94453/) |

## Published Reports

- [CVE-2026-94453: Remote use-after-free in an IKE-over-TCP endpoint](libreswan/IKE_OVER_TCP_ENDPOINT_UAF_CVE-2026-94453.md) — [official Libreswan advisory](https://libreswan.org/security/CVE-2026-94453/)
- [Pre-authentication use-after-free in IPSECKEY DNS cleanup](libreswan/IPSECKEY_DNS_UAF_REPORT.md) — [upstream issue #3071](https://github.com/libreswan/libreswan/issues/3071)


