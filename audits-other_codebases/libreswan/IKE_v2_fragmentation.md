# IKEv2 fragment-queue resource exhaustion



## Summary

Pluto allows fragmented IKE_AUTH requests up to 32 SKF payloads. `collect_v2_incoming_fragment()` does not impose any byte limit on the fragment queue. Each fragment is cloned into heap and retained during the half-open IKE SA. If the set never complets reassembly does not occure and the memory is ocupied untill `EVENT_v2_DISCARD`event.

There is also a stronger, authenticated retention variant visible in the
source: after queuing 31 of 32 SKF packets, the peer can send a complete SK
request for the same exchange and Message ID.  The SK path processes the
unfragmented request but does not discard the pre-existing SKF queue.  If the
IKE_AUTH request succeeds, the queue moves with the now-established IKE SA and
is retained until that SA is deleted or replaced.  This variant is
source-confirmed but still requires an end-to-end runtime reproducer.


## Severity assessment

**Severity: Medium.**

The condition is remotely reachable before peer identity authentication and
the responder does not enforce an aggregate byte budget for incomplete
fragment queues. This is a valid pre-authentication resource-retention
primitive, but the demonstrated impact and the practical attack economics
support a Low rating.

The Low rating above applies to the demonstrated unauthenticated, temporary
retention variant.  The authenticated persistent-retention upgrade described
below may justify a higher rating, potentially Medium, if an end-to-end test
confirms that one authenticated peer can keep enough concurrent established
IKE SAs alive to cause material memory pressure.  It should not be presented
as a runtime-confirmed severity upgrade yet.

## Authenticated persistence upgrade: `SKF x31 -> SK`

### Status

- cleanup defect: **confirmed by source inspection**;
- transition from half-open to established while retaining the queue:
  **confirmed by source inspection**;
- persistent memory growth in a live Pluto process: **not yet tested**;
- practical multi-SA scaling with `uniqueids` and connection replacement:
  **not yet tested**.

### Packet sequence

```text
authenticated-capable initiator                 Pluto responder

IKE_SA_INIT -----------------------------------> creates half-open IKE SA
<----------------------------------------------- IKE_SA_INIT response

SKF 1/32, Message ID 1 ------------------------> allocate fragment queue
SKF 2/32 .. SKF 31/32, Message ID 1 -----------> retain about 2.2 MiB

SK complete IKE_AUTH, Message ID 1 ------------> decrypt SK independently
                                                  authenticate peer
                                                  establish IKE SA
                                                  advance Message ID window
                                                  fragment queue is not freed

                                                  memory remains attached to
                                                  established IKE SA until
                                                  delete/rekey/replacement
```

The complete SK must contain a valid IKE_AUTH request and therefore requires
valid peer credentials.  The 31 SKF packets and the SK packet are independently
encrypted and integrity protected using the provisional keys established by
IKE_SA_INIT.

### Why the sequence is accepted

1. `collect_v2_incoming_fragment()` stores the incomplete queue in
   `st_v2_msgid_windows.responder.incoming_fragments`.
2. Receiving incomplete fragments does not set `responder.wip`; the comment in
   `is_duplicate_request_msgid()` explicitly states that `wip` starts only
   after all fragments decrypt and are reassembled.
3. Consequently, a complete SK request using the same next Message ID is not
   rejected as work already in progress.
4. `process_packet_with_secured_ike_sa()` handles SK and SKF in separate
   branches.  The SK branch calls `ikev2_decrypt_msg()` and does not inspect or
   free `window->incoming_fragments`.
5. A successful IKE_AUTH calls `v2_ike_sa_established()` and then
   `v2_msgid_finish()`.  `v2_msgid_finish()` advances `recv`, `sent`, and `wip`,
   but does not clear `incoming_fragments`.
6. `free_v2_incoming_fragments()` is called when reassembly succeeds, all saved
   fragments prove invalid, or `free_v2_message_queues()` runs during state
   destruction.  It is not called merely because an SK superseded an
   incomplete SKF message.

### Why retention becomes substantially longer

The successful responder IKE_AUTH transition uses `EVENT_v2_REPLACE`.  This
removes the short `EVENT_v2_DISCARD` protection used for the half-open exchange
and schedules the normal established-SA replacement lifecycle.  The default
IKE SA lifetime is eight hours (`IKE_SA_LIFETIME_DEFAULT`), although liveness,
explicit delete, rekey, connection replacement, or local policy may shorten
the actual retention.

The established state belongs to `CAT_ESTABLISHED_IKE_SA`, not
`CAT_HALF_OPEN_IKE_SA`.  Therefore the retained queue no longer contributes to
`total_halfopen_ike()` and is outside both `ddos-ike-threshold` and
`max-halfopen-ike`.  Those controls do not provide an aggregate memory limit
for this variant.

### Important constraints on the upgrade

This is not an unauthenticated persistence primitive:

- the final SK must pass IKE_AUTH using credentials accepted by the responder;
- each retained queue still costs the sender roughly as many bytes as the
  responder retains;
- default `uniqueids` behavior can delete older established connections using
  the same peer identity, depending on connection instantiation and peer
  address;
- `wipe_old_connections()` explicitly skips this cleanup for a server using a
  group PSK, and it is also skipped when `uniqueids=no`;
- SA lifetime, DPD/liveness, rekey, operator actions, and cgroup limits remain
  effective outer bounds.

The strongest practical scenario is therefore a malicious or compromised
credential on a deployment that permits many simultaneous established SAs,
uses group credentials, disables `uniqueids`, or permits many attacker-owned
identities.  Runtime testing must determine the actual concurrency attainable
under representative configurations before assigning the upgraded variant a
final severity.

### Why the demonstrated pre-authentication variant remains Low

1. **There is no significant bandwidth amplification.** The attacker must
   transmit approximately the amount of fragment data retained by the
   responder. One maximized queue requires about 31 × 65,000 bytes of traffic
   to retain approximately 2.18 MiB of resident memory.
2. **Each queue has a hard per-SA bound.** `MAX_IKE_FRAGMENTS` caps a fragmented
   message at 32 fragments, and omitting one fragment limits the demonstrated
   retained allocation to roughly 2.2 MiB per incomplete IKE SA.
3. **The attack is stateful and cryptographically non-trivial.** The initiator
   must complete its own `IKE_SA_INIT` exchange, perform Diffie-Hellman work,
   derive provisional IKE keys, and send integrity-valid encrypted fragments.
   This is not a blind, spoofed, single-packet allocation primitive.
4. **Retention is temporary.** `EVENT_v2_DISCARD` deletes unfinished SAs and
   releases their fragment queues. The tested 5.3.2 package retained them for
   approximately 200 seconds; current mainline uses a 30-second exchange
   timeout.
5. **Large impact requires many concurrent successful exchanges.** DDoS
   cookies, `max-halfopen-ike`, CPU/DH cost, packet loss, IP fragmentation, and
   state timeouts all constrain the number of complete fragment queues that can
   coexist.
6. **Standard service isolation limits blast radius.** Administrators can
   constrain Pluto with systemd/cgroup `MemoryHigh`, `MemoryMax`, swap limits,
   and network rate controls. In the pressure test, the explicitly configured
   `MemoryHigh` throttled the service before the artificial `MemoryMax` was
   reached. This is operational mitigation, not an intrinsic protocol fix.



## Relevant components

| Component | Function | Role |
|---|---|---|
| `programs/pluto/iface_udp.c` | `udp_read_packet()` | Receives the UDP datagram. |
| `programs/pluto/msgdigest.c` | `alloc_md()` | Clones the received packet into a `msg_digest`. |
| `programs/pluto/demux.c` | `process_md()` | Parses the IKE header and dispatches IKEv2 processing. |
| `programs/pluto/ikev2.c` | `ikev2_process_packet()` | Finds the half-open IKE SA and routes the protected request. |
| `programs/pluto/ikev2_parent.c` | `process_v2_request_no_skeyseed()` | Accepts the first SKF structurally and starts deferred DH/SKEYSEED work. |
| `programs/pluto/ikev2_message.c` | `collect_v2_incoming_fragment()` | Clones each accepted fragment without tracking aggregate queued bytes. |
| `programs/pluto/crypt_dh.c` | `submit_dh_shared_secret()` | Submits the pre-authentication DH computation to a helper thread. |
| `programs/pluto/ikev2_send.c` | `free_v2_incoming_fragments()` | Releases queued fragment chunks and the retained message digest. |
| `programs/pluto/timer.c` | `EVENT_v2_DISCARD` handling | Deletes an incomplete IKE SA and triggers queue cleanup. |
| `lib/libswan/alloc.c` | `allocate()` | Treats allocation failure as fatal through `llog_passert()`. |

## Protocol and allocation flow

```text
UNAUTHENTICATED INITIATOR          PLUTO RESPONDER                  HEAP / WORKER
          |                              |                               |
          |--- IKE_SA_INIT request ----->|                               |
          |    SA, KEi, Ni,              | create half-open IKE SA       |
          |    fragmentation support     | generate KEr, Nr, SPIr        |
          |                              | schedule EVENT_v2_DISCARD     |
          |<-- IKE_SA_INIT response -----|                               |
          |                              |                               |
          | derive provisional IKE keys  |                               |
          | identity is NOT authenticated|                               |
          |                              |                               |
          |--- SKF fragment 1/32 ------->| process_v2_request_no_skeyseed|
          |    valid integrity           |       |                       |
          |                              |       +--> collect fragment   |
          |                              |       |      |                |
          |                              |       |      +--> clone packet |
          |                              |       |           ~65 KiB     |
          |                              |       |                       |
          |                              |       +--> submit DH -------->|
          |                              |              SKEYSEED helper  |
          |                              |                               |
          |--- SKF fragments 2..31 ----->| collect each distinct index   |
          |    ~65 KiB each              |       |                       |
          |                              |       +--> clone each packet  |
          |                              |                               |
          |--- fragment 32 omitted       | queue remains incomplete      |
          |                              |                               |
          |                              | incoming_fragments            |
          |                              |   total = 32                   |
          |                              |   count = 31                   |
          |                              |   retained md reference        |
          |                              |   31 owned fragment chunks     |
          |                              |            |                  |
          |                              |            +--> ~2.2 MiB RAM  |
          |                              |                               |
          |          retention window    |                               |
          |                              |                               |
          |                              | EVENT_v2_DISCARD               |
          |                              |       |                       |
          |                              |       +--> delete IKE SA       |
          |                              |       +--> free fragments ---->|
          |                              |                               |
```


## Root cause

The code does not impose an aggregate memory bound.

### Existing partial mitigations

The implementation contains several guards that limit malformed input or bound
individual parts of the operation, but none bounds the aggregate memory retained
for incomplete fragment queues:

| Existing mechanism | What it limits | Why it is insufficient |
|---|---|---|
| UDP input is limited to 65,536 bytes and the SKF length is checked against the received packet. | The size of one datagram or fragment. | Up to 31 distinct near-maximum-size fragments can still be retained by one incomplete SA. |
| Fragment numbers must be in the range `1..total`, and `total` is capped at `MAX_IKE_FRAGMENTS` (32). | The number of fragment slots associated with one message. | The count limit still permits approximately 2.18 MiB of measured retained memory per incomplete SA. |
| Fragment totals and exchange types must remain consistent, and duplicate indices are rejected. | Malformed, mixed, or repeated fragments. | An attacker can send 31 valid fragments with distinct indices and intentionally omit fragment 32. |
| Fragment integrity and encryption are checked after SKEYSEED becomes available. | Blind or spoofed injection of invalid encrypted fragments. | An unauthenticated initiator can complete its own `IKE_SA_INIT`, derive valid keys, and generate integrity-valid fragments before identity authentication. |
| `EVENT_v2_DISCARD` eventually deletes the incomplete IKE SA and releases its fragments. | The lifetime of one retained queue. | Retention lasts up to 200 seconds in Libreswan 5.3.2; an attacker can continuously create replacement SAs. Mainline reduces this timeout to 30 seconds but does not enforce a byte limit. |
| DDoS cookies are required after the default `ddos-ike-threshold` of 25,000 half-open SAs. | Source-spoofed creation of large numbers of half-open SAs. | A reachable attacker can return the cookie, and the default threshold is far above the number of queues that can pressure a typical host. |
| `max-halfopen-ike` defaults to 50,000. | The total number of half-open IKE SAs. | This is a count limit rather than a memory budget and theoretically permits more than 100 GiB at the measured per-SA retention. Lowering it also allows an attacker to exhaust the available connection slots. |

These mechanisms reduce or bound parts of the attack, but the missing invariant
is:

> A peer, IKE SA, and the daemon as a whole must have bounded aggregate bytes
> retained for incomplete fragment reassembly.

The 32 fragment count cap allows 2.2 MiB of retained data for each half opened SA because every fragment can use the maximum udp packet size.
The default `max-halfopen-ike` limit of half allowed connections is 50,000. A potential attack would eat 12gb of ram with 5462 connections(at the measured 2.18 MiB per incomplete SA). This scenario is bounded by the kernel memory allocations for the process and cpu usage.


## Confirmed runtime result

Environment:

- Libreswan package: `5.3.2-2.fc44`
- Platform: Fedora 44, x86-64
- Transport: UDP/500
- Reproducer: 31 integrity-valid fragments carrying 65,000 cleartext bytes
  each, with `total=32`; fragment 32 omitted


Clean baseline:

```text
PID:       23475
VmRSS:     21112 kB
RssAnon:    4116 kB
```

After the controlled run:

```text
PID:       23475                  (unchanged)
VmRSS:     25620 kB               (+4508 kB)
RssAnon:    8572 kB               (+4456 kB)
States:    2 x IKE_SA_INIT_R      (both incomplete)
```

The observed anonymous resident-memory increase was therefore approximately:

```text
4456 kB / 2 incomplete SAs = 2228 kB per SA ≈ 2.18 MiB per SA
```

The server log recorded fragments 1 through 31, each declaring a total of 32.
The missing fragment prevented reassembly. A later log showed:

```text
timer_event_cb: processing EVENT_v2_DISCARD ... for IKE SA #3
free_v2_incoming_fragments()
```

Under sufficient pressure, one of the following may occur:

1. New IKE allocations fail. Libreswan's allocation wrapper treats allocation
   failure as fatal through `llog_passert()`, which can terminate Pluto.
2. A systemd/cgroup memory limit kills or stops the service.
3. The kernel OOM killer terminates Pluto or another process.
4. Swapping and allocator pressure delay or prevent legitimate IKE exchanges.

None of these terminal outcomes was produced by the controlled test, so they
must be described as potential consequences rather than observed results.

### Bounded pressure/OOM attempt

A later laboratory run attempted to reach a conservative 3 GiB target using
1,599 asynchronous client initiations. The responder service was deliberately
configured with:

```text
MemoryHigh=402653184   (384 MiB)
MemoryMax=536870912    (512 MiB)
MemorySwapMax=0
```

Observed responder results:

```text
Maximum MemoryCurrent:       431824896 bytes (~412 MiB)
Maximum Pluto VmRSS:             59504 kB
Maximum Pluto RssAnon:           42480 kB
Maximum concurrent incomplete SAs:  30
memory.events high:               3143
memory.events max:                   0
memory.events oom:                   0
memory.events oom_kill:              0
```

The original Pluto PID (`1625`) remained alive throughout the pressure window.
A later PID (`3775`) appeared only after the limits had been restored to
`infinity` and the service was restarted during cleanup; it is not evidence of
an OOM restart. The client accepted all 1,599 asynchronous initiation commands,
but that does not mean all of them completed `IKE_SA_INIT` or created complete
31-fragment queues on the responder.

This run confirms meaningful resource pressure and effective cgroup
throttling, but it does not confirm denial of service. In particular, the
`memory.high` counter increased while `memory.max`, `oom`, and `oom_kill`
remained zero. The cgroup thresholds were artificial laboratory controls and
must not be presented as default Libreswan behavior.

## Reproduction steps

1. Prepare two isolated Fedora VMs:
   - east/responder: `192.168.122.31`
   - west/initiator: `192.168.122.160`
2. Install and configure an unmodified Libreswan responder on east using
   `candidate33_server.conf` and `candidate33_ipsec.secrets`.
3. Allow inbound UDP/500 on east and start Pluto.
4. Apply `candidate33_client_impair.patch` to the client build. The patch adds
   a test impairment that creates 32 protected IKEv2 fragments, sends
   fragments 1 through 31 with 65,000 cleartext bytes each, and omits
   fragment 32.
5. Install the patched build on west and load `candidate33_client.conf`.
6. Record the responder's PID, `VmRSS`, and `RssAnon`.
7. Run the client trigger:

### Responder setup and baseline

Run this on east and keep the same shell open for the final measurement:

```bash
sudo cp /tmp/candidate33_server.conf /etc/ipsec.conf
sudo cp /tmp/candidate33_ipsec.secrets /etc/ipsec.secrets
sudo chmod 600 /etc/ipsec.secrets

server_iface=$(ip route get 192.168.122.160 |
  awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
server_zone=$(sudo firewall-cmd --get-zone-of-interface="$server_iface")
if [ -z "$server_zone" ] || [ "$server_zone" = "no zone" ]; then
  server_zone=$(sudo firewall-cmd --get-default-zone)
fi
sudo firewall-cmd --zone="$server_zone" --add-port=500/udp

sudo systemctl restart ipsec
sleep 2

sudo systemctl is-active ipsec
sudo ss -lunp | grep ':500'

pid_before=$(pgrep -o -x pluto)
before_rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid_before/status")
before_anon=$(awk '/^RssAnon:/ {print $2}' "/proc/$pid_before/status")

echo "PID before: $pid_before"
echo "VmRSS before: $before_rss kB"
echo "RssAnon before: $before_anon kB"
```

### Instrumented initiator setup

Run this on west after copying the client archive, configuration, secrets, and
trigger script into `/tmp`:

```bash
sudo systemctl stop ipsec 2>/dev/null || true
sudo pkill -x pluto 2>/dev/null || true
sudo tar -C / -xzf /tmp/candidate33-client-build.tar.gz
sudo cp /tmp/candidate33_client.conf /etc/ipsec.conf
sudo cp /tmp/candidate33_ipsec.secrets /etc/ipsec.secrets
sudo chmod 600 /etc/ipsec.secrets
sudo chmod 755 /tmp/candidate33_client_trigger.sh
sudo install -d -m 755 /run/pluto

sudo /usr/local/libexec/ipsec/pluto \
  --config /etc/ipsec.conf \
  --nofork \
  --stderrlog \
  >/tmp/candidate33-client-console.log 2>&1 &

sleep 2
pgrep -a -x pluto

sudo /usr/local/sbin/ipsec addconn \
  --config /etc/ipsec.conf \
  candidate33

sudo /usr/local/sbin/ipsec whack --impair help |
  grep v2_incomplete_fragments
```

### Trigger

Run this on west:

```bash
sudo env \
  IPSEC_COMMAND=/usr/local/sbin/ipsec \
  FRAGMENT_BYTES=65000 \
  TARGET_MIB=1 \
  SA_LIMIT=1 \
  REPORT_EVERY=1 \
  SETTLE_SECONDS=2 \
  /tmp/candidate33_client_trigger.sh
```

### Responder verification

Return to the same east shell used for the baseline:

```bash
pid_after=$(pgrep -o -x pluto)
after_rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid_after/status")
after_anon=$(awk '/^RssAnon:/ {print $2}' "/proc/$pid_after/status")

echo "PID after: $pid_after"
echo "VmRSS after: $after_rss kB"
echo "RssAnon after: $after_anon kB"
echo "VmRSS increase: $((after_rss - before_rss)) kB"
echo "RssAnon increase: $((after_anon - before_anon)) kB"

test "$pid_before" = "$pid_after" && echo "Pluto PID unchanged"

sudo /usr/sbin/ipsec whack --showstates |
  grep 'candidate33.*IKE_SA_INIT_R'

sudo grep -F 'received IKE encrypted fragment' \
  /tmp/candidate33-server-pluto.log | tail -31
```

The expected result is one incomplete `IKE_SA_INIT_R` state, log entries for
fragments 1 through 31 declaring a total of 32, no fragment 32, an unchanged
Pluto PID, and an `RssAnon` increase of approximately 2.2 MiB.

## Security impact assessment

Confirmed:

- remotely reachable over UDP/500;
- no authenticated peer identity is required;
- approximately 2.2 MiB resident RAM retained per incomplete IKE SA;
- memory growth is approximately linear across concurrent incomplete SAs;
- first SKF starts deferred DH/SKEYSEED work;
- cleanup occurs only when the fragment set completes, becomes invalid, or the
  owning IKE SA is deleted.

The current evidence supports a pre-authentication resource-retention
primitive, but not a demonstrated denial of service. Given the near-1:1 traffic
cost, bounded per-SA allocation, temporary retention, required cryptographic
setup, admission controls, and successful operational containment in testing,
the appropriate severity is Low.

## Recommended remediation

1. When a valid SK message supersedes an incomplete SKF message for the same
   Message ID window, reject the mixed representation or free the stale SKF
   queue before processing SK.
2. Clear any incomplete incoming-fragment queue when the corresponding Message
   ID is finished or advanced, with regression assertions for stale queues.
3. Track cumulative queued fragment bytes per IKE SA.
4. Reject and free a queue when a conservative per-SA byte limit is exceeded.
5. Add per-source and daemon-wide fragment-byte accounting, not only SA-count
   accounting.
6. Apply a short fragment-assembly deadline that is independent of the broader
   exchange/state timeout.
7. Include retained fragment bytes in DDoS admission decisions.
8. Consider delaying expensive DH/SKEYSEED work until the first protected
   message satisfies stricter size/rate admission checks.
9. Add regression tests for 31 maximum-sized fragments with one missing, many
   concurrent incomplete SAs, cleanup on timeout, allocation accounting, and
   `SKF x31 -> SK` followed by successful IKE_AUTH.  The final test must verify
   that no fragment bytes remain attached to the established IKE SA.

## Reproducer files

The controlled laboratory reproducer, configurations, and execution commands
are in [`candidate33/README.md`](candidate33/README.md). The client-only test
patch does not modify the responder under test.
