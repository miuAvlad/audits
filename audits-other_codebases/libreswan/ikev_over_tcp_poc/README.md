# IKE-over-TCP endpoint use-after-free reproducer

This is a bounded reproducer for CVE-2026-94453. It creates an unauthenticated
IKEv2 state over TCP, closes the original stream, and sends a duplicate request
through a new stream to exercise the stale endpoint reference.

Run it only against a disposable test VM. A vulnerable Pluto process may
terminate and be restarted by systemd, interrupting all active IPsec tunnels.

## Requirements

- a Libreswan responder with IKE-over-TCP enabled;
- TCP/4500 reachable from the initiator;
- Python 3 on the initiator;
- an x86-64 build whose `struct iface_endpoint` allocation matches the
  reproducer's tested 192-byte heap-reuse mode.

The vulnerable path is reached before peer authentication. No PSK or private
key is included in this directory.

## Prepare the responder

Copy this directory to the responder and run:

```bash
sudo ./prepare_responder.sh RESPONDER_IP INITIATOR_IP
```

The script renders `responder.conf.in`, saves the previous configuration as
`/etc/ipsec.conf.ike-tcp-uaf-backup`, installs the test configuration, and
restarts IPsec. Open TCP/4500 in the VM firewall if required.

## Run the trigger

From the initiator VM:

```bash
python3 candidate16_send_forged_frame.py RESPONDER_IP \
  --source INITIATOR_IP \
  --intermediate-endpoint \
  --free-intermediate-before-trigger \
  --reuse-stale-chunk-with-trigger
```

The script performs these steps:

1. send a valid unauthenticated IKE_SA_INIT over IKE-over-TCP;
2. record the responder SPI and close the first stream;
3. allocate and release an intermediate endpoint;
4. keep a third transport endpoint open;
5. send a 192-byte allocation containing a duplicate IKE_AUTH header.

On the responder, inspect the service and coredump state:

```bash
pgrep -a -x pluto
sudo coredumpctl list pluto --no-pager | tail -n 5
sudo journalctl -u ipsec.service --since '-5 minutes' --no-pager
```

`candidate16_host_availability_monitor.py` can independently monitor whether
TCP/4500 remains reachable:

```bash
python3 candidate16_host_availability_monitor.py RESPONDER_IP --duration 60
```

## Restore the responder

```bash
sudo cp -a /etc/ipsec.conf.ike-tcp-uaf-backup /etc/ipsec.conf
sudo systemctl restart ipsec
```

