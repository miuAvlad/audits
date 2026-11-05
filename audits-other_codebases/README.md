# Systems Security Research

My public Libreswan work covers memory safety and resource exhaustion in the Pluto IKE daemon. The reports include affected configurations, root-cause analysis, bounded reproductions, and upstream disclosure references.

| Finding | Demonstrated impact | Evidence and upstream status |
| --- | --- | --- |
| [IKE-over-TCP endpoint use-after-free](libreswan/IKE_OVER_TCP_ENDPOINT_UAF_CVE-2026-94453.md) | Remote unauthenticated Pluto crash and tunnel interruption | [CVE-2026-94453](https://libreswan.org/security/CVE-2026-94453/) · [PoC](libreswan/ikev_over_tcp_poc/README.md) · fixed in 5.3.3 and 5.4.1 |
| [IPSECKEY DNS cleanup use-after-free](libreswan/IPSECKEY_DNS_UAF_REPORT.md) | Pre-authentication Pluto crash under the specified DNS configuration | [Upstream issue #3071](https://github.com/libreswan/libreswan/issues/3071) · [fix on `main`](https://github.com/libreswan/libreswan/commit/b04c3a27f7a047260d8fa99c460cc49f345da9c6) · [PoC](libreswan/ipsec_dns_poc/README.md) |
| [IKEv2 fragment-queue resource retention](libreswan/IKE_v2_fragmentation.md) | Bounded reproduction of temporary, unauthenticated memory retention; stronger variant has source-level evidence only | [Upstream issue #3079](https://github.com/libreswan/libreswan/issues/3079) · [PoC](libreswan/ikev2_fragmentation_poc/README.md) |

The reports distinguish reproduced impact from source-level hypotheses. Findings are published after remediation is public or disclosure is authorized.
