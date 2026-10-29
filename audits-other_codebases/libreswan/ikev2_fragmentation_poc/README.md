# Bounded IKEv2 fragment-queue retention reproducer

This reproducer accompanies the
[public report](../IKE_v2_fragmentation.md). It sends 31 valid encrypted SKF
packets that advertise 32 total fragments and deliberately omits fragment 32.

The responder is not patched. A client-only test impairment constructs the
fragment sequence. The public trigger defaults to one incomplete IKE SA and
has a hard limit of eight; it is not an OOM or service-termination test.

Use two disposable VMs. The setup replaces their active IPsec configuration.

## 1. Generate disposable configuration

On the host:

```bash
./render_lab.sh RESPONDER_IP INITIATOR_IP
```

This creates `generated/`, which is ignored by Git, and generates a random PSK
used only by the two lab VMs. No credential is committed to the repository.
An optional third argument selects a different output directory, which is
useful when validating the renderer without creating files in the checkout.

## 2. Build the instrumented initiator

Apply `client_impair.patch` to a clean checkout matching the source revision
under test. Build and install that result only on the initiator VM:

```bash
git apply --check /path/to/client_impair.patch
git apply /path/to/client_impair.patch
make -j2 base
```

The patch adds the disabled-by-default impairment:

```text
v2_incomplete_fragments:<cleartext-bytes>
```

Do not install this instrumented build on the responder or use it in
production.

## 3. Copy the lab files

```bash
./copy_to_vms.sh user@RESPONDER user@INITIATOR
```

Install `server.conf` and `ipsec.secrets` as `/etc/ipsec.conf` and
`/etc/ipsec.secrets` on the responder, then restart its packaged IPsec service.
Install `client.conf` and the same generated secrets file on the initiator and
start the instrumented Pluto build.

Open UDP/500 between the two VMs if their firewall requires it.

## 4. Record the responder baseline

```bash
sudo /tmp/ikev2-fragmentation-poc/observe_responder.sh
```

Record `VmRSS` and `RssAnon`, then run the trigger on the initiator:

```bash
sudo env \
  IPSEC_COMMAND=/usr/local/sbin/ipsec \
  SA_COUNT=1 \
  FRAGMENT_BYTES=65000 \
  /tmp/ikev2-fragmentation-poc/trigger.sh
```

Run `observe_responder.sh` again. Expected evidence includes:

- one incomplete `IKE_SA_INIT_R` state;
- log entries for fragments 1 through 31, each declaring a total of 32;
- no fragment 32;
- approximately 2.18 MiB of retained resident memory per incomplete SA;
- an unchanged Pluto PID.

The state and fragment queue are released when the responder's discard timer
expires.
