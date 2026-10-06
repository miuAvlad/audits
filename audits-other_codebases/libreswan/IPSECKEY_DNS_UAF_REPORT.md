# Pre-authentication Use-After-Free in IPSECKEY DNS Cleanup Causes Pluto Denial of Service

## Report metadata

- Reporter: `miuAvlad`
- Vendor: The Libreswan Project
- Product: Libreswan Pluto IKE daemon
- CWE: CWE-416 — Use After Free
- Proposed severity: High
- CVSS 3.1: 7.5 — `CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H`

## Summary


IKEv2 with `rightrsasigkey=%dnsondemand` and `dns-match-id=yes` forces pluto to perform two DNS queries:
1. IPSECKEY for the initiator public key
2. an A-record lookup to check if the FQDN identity resolves the IKE source address

When A record is provided syncronously from libunbound's cache and does not match the initiator address it returns DNS_FATAL.
Two possible scenarios can occur that may cause an UAF and crash the Pluto daemon.
- first request is pending while A callback frees the `ike->sa.ipseckey_dnsr` due to initiator address not corresponding to the FQDN address, later the trigger is the `ret_a != DNS_SUSPEND && ret_a != DNS_OK` branch which tries to dealocate the local pointer `dnsr_idi`.
- first request is resolved after `dns_qry_start(dnsr_idi)` with DNS_OK which frees the memory from the local pointer `dnsr_idi`, the later A callback returning DNS_FATAL triggers the `ret_a != DNS_SUSPEND && ret_a != DNS_OK` branch which tries to dealocate `dnsr_idi` again.


## Security impact

An unauthenticated network attacker can crash the Pluto daemon on a vulnerable
configuration. The demonstrated impact is denial of service.

## Affected versions

- Confirmed affected runtime: `libreswan-5.3.2-2.fc44.x86_64`
- Source checkout analyzed: `v5.4-346-gb49d6bcaeb`
- Exact first affected version: `v3.25`
- Exact last affected version: `[TO BE DETERMINED]`


## Required configuration and attack preconditions

The target is reachable when all of the following conditions hold:

1. Pluto is built with IPSECKEY, libunbound, and LDNS support.
2. The responder accepts an IKEv2 connection that uses
   `rightrsasigkey=%dnsondemand`.
3. Forward identity validation is enabled with `dns-match-id=yes`.
4. The initiator supplies an FQDN as IDi and declares RSA or digital-signature
   authentication.
5. The IPSECKEY lookup either remains pending (`DNS_SUSPEND`) or completes
   synchronously with an acceptable result (`DNS_OK`). A completed lookup that
   returns `DNS_FATAL` stops processing before the `A` lookup.
6. The FQDN's `A` record does not match the initiator's IKE source IP address.
7. The `A` response is already available in libunbound's cache, so its callback
   runs synchronously and the address mismatch makes the lookup return
   `DNS_FATAL`.

## Root cause

`responder_fetch_idi_ipseckey()` allocates the IPSECKEY request and stores its
address in the local variable `dnsr_idi`:

```c
struct p_dns_req *dnsr_idi = ipseckey_qry_st_init(...);
ret_idi = dns_qry_start(dnsr_idi);
```

### Firs case

For a synchronous callback in which the DNS returns DNS_OK, `dns_qry_start()` frees the request before
returning:

```c
ret = dnsr->dns_status;
if (dnsr->dns_status == DNS_SUSPEND) {
        dnsr->cache_hit = false;
} else {
@>        free_ipseckey_dns(dnsr);
}
return ret;
```

The caller does not invalidate its local pointer. If later `A` lookup returns an address that does not match the initiator’s IKE source IP, the execution reaches the branch in which it frees again the local pointer `dnsr_idi`:

```c
if (ret_a != DNS_SUSPEND && ret_a != DNS_OK) {
        free_ipseckey_dns(dnsr_idi); /* stale pointer */
}
```

`free_ipseckey_dns()` accesses fields of the freed object before checking
whether it is still present in the global request list:

```c
if (d->ub_async_id != 0) {
        ub_cancel(d->ctx, d->ub_async_id);
        d->ub_async_id = 0;
}

md_delref(&d->md);
free_logger(&d->logger, HERE);
```

Therefore the second cleanup immediately dereferences freed memory.

### Second case

When dns_qry_start(dnsr_idi) returns DNS_SUSPEND, the IPSECKEY request is still pending, so the caller stores its pointer in `ike->sa.ipseckey_dnsr`for later callback handling.

```c
ret_idi = dns_qry_start(dnsr_idi);

	if (ret_idi != DNS_SUSPEND && ret_idi != DNS_OK) {
		return ret_idi;
	}

	if (ret_idi == DNS_SUSPEND) {
@>		ike->sa.ipseckey_dnsr = dnsr_idi;
	}
```

If the `A` lookup return address does not match the IKE source IP `idi_a_fetch_continue()` frees the memory from `ike->sa.ipseckey_dnsr`.

```c
if (ike->sa.st_connection->config->dns_match_id) {
		struct id id = ike->sa.st_connection->remote->host.id;
		if (id.kind == ID_FQDN) {
			dnsr_a = qry_st_init(ike, md, LDNS_RR_TYPE_A, "A",
@>					     idi_a_fetch_continue,
					     callback);
			if (dnsr_a == NULL) {
				free_ipseckey_dns(dnsr_idi);
				return DNS_FATAL;
			}
			dnsr_a->validate_address_cb = validate_address;

			ret_a = dns_qry_start(dnsr_a);
		}
	}
```
Inside `idi_a_fetch_continue`:
```c
	if (dnsr->rcode == 0 && dnsr->fwd_addr_valid) {
		err = false;
	} else {
		if (ike->sa.ipseckey_dnsr != NULL) {
@>			free_ipseckey_dns(ike->sa.ipseckey_dnsr);
			ike->sa.ipseckey_dnsr = NULL;
		}
		err = true;
	}
```
Later the DNS_FATAL execution enters this branch.
```c
if (ret_a != DNS_SUSPEND && ret_a != DNS_OK) {
        free_ipseckey_dns(dnsr_idi); /* stale pointer */
}
```

## Attack flow

The attack path nees 2 conections, one for prewarming the cache of libunbound and one for the actual trigger.
Each negotiation creates its own DNS request objects, but both A requests ask the same logical DNS question:

QNAME  = attacker.uaf2-poc.net.
QTYPE  = A
QCLASS = IN

```text
Remote initiator                         Vulnerable Pluto responder
      |                                           |
      |-- IKE_SA_INIT (IKE SA #1) --------------->|
      |<--------------------------- IKE_SA_INIT --|
      |                                           |
      |-- encrypted IKE_AUTH (IKE SA #1) -------->|
      |   IDi = attacker-controlled FQDN          |
      |                                           |-- new IPSECKEY request (async)
      |                                           |-- new A request (async)
      |                                           `-- A answer cached by libunbound
      |                                               address mismatch; AUTH fails
      |                                           |
      |-- IKE_SA_INIT (IKE SA #2) --------------->|
      |<--------------------------- IKE_SA_INIT --|
      |-- encrypted IKE_AUTH (IKE SA #2) -------->|
      |   same IDi FQDN                           |-- new IPSECKEY request R1: pending
      |                                           |-- new A request R2: same FQDN/type
      |                                           |-- shared libunbound cache returns A
      |                                           |   synchronously; address mismatch
      |                                           |-- A callback frees R1 via IKE SA #2
      |                                           |-- local pointer to R1 remains stale
      |                                           |-- error path uses stale pointer
      |                                           `-- SIGSEGV
      |                                               systemd restarts Pluto
```



## Proof of concept

The attached `UAF_2` directory contains the complete two-VM reproducer:

- `uaf2_prepare_responder.sh` — configures the vulnerable responder;
- `uaf2_prepare_initiator.sh` — configures the initiator and authoritative DNS;
- `uaf2_trigger.sh` — performs cache warm-up and trigger negotiations;
- `uaf2_responder.conf.in` and `uaf2_initiator.conf.in` — connection templates;
- `uaf2_named.conf` and `uaf2-poc.net.zone.in` — authoritative DNS data.

The lab DNS zone is unsigned, so the reproducer enables allow_dns_insecure to let Pluto process its responses. This impairment is specific to the lab, not a requirement of the vulnerable code path. A properly signed attacker-controlled domain could provide DNSSEC-validated IPSECKEY and A records, including an A record that does not match the initiator’s IKE source address.

### Test topology

```text
VM1 / vulnerable responder: 192.168.122.31
VM2 / initiator and DNS:     192.168.122.160
```

### Reproduction

Prepare VM2:

```bash
sudo /tmp/uaf2/uaf2_prepare_initiator.sh /tmp/uaf2
```

Prepare VM1 and record its PID:

```bash
sudo /tmp/uaf2/uaf2_prepare_responder.sh /tmp/uaf2
PID_BEFORE=$(pgrep -xo pluto)
echo "PID before: ${PID_BEFORE}"
```

Run the trigger on VM2:

```bash
sudo /tmp/uaf2/uaf2_trigger.sh 2
```

Check VM1:

```bash
PID_AFTER=$(pgrep -xo pluto || true)
echo "PID before: ${PID_BEFORE}"
echo "PID after:  ${PID_AFTER:-stopped}"
```

## Observed result

Tested package:

```text
libreswan-5.3.2-2.fc44.x86_64
Executable: /usr/libexec/ipsec/pluto
Termination signal: SIGSEGV (signal 11)
Coredump status: present
```

Two confirmed reproductions produced these PID transitions:

```text
2489 -> 2560
2560 -> 2731
```

The coredump recorded the following responder-side stack:

```text
release_whack
free_logger
free_ipseckey_dns
responder_fetch_idi_ipseckey
process_v2_IKE_AUTH_request_post_cert_decode
v2_dispatch
process_protected_v2_message
```
## Suggested remediation

Centralize cancellation of a pending IPSECKEY request through
`ike->sa.ipseckey_dnsr`, clearing that field before freeing the request.
Do not use the local `dnsr_idi` pointer for cleanup after `dns_qry_start()`:
a synchronous lookup may already have freed the request.

Apply the same rule in the A-query callback and all caller error paths.
Test both IPSECKEY outcomes (`DNS_SUSPEND` and synchronous `DNS_OK`) with
a synchronous, mismatching A response.


## Attachments

- `uaf2_prepare_responder.sh`
- `uaf2_prepare_initiator.sh`
- `uaf2_trigger.sh`
- `uaf2_responder.conf.in`
- `uaf2_initiator.conf.in`
- `uaf2_named.conf`
- `uaf2-poc.net.zone.in`
