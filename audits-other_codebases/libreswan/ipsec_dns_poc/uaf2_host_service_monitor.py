#!/usr/bin/env python3
"""Monitor Pluto's PID/restart count on VM1 over SSH during the UAF_2 run."""

import argparse
import signal
import subprocess
import time
from datetime import datetime


signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def query(target: str, timeout: float) -> tuple[dict[str, str], str | None]:
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={max(1, int(timeout))}",
        target,
        "systemctl show ipsec --no-pager "
        "--property=ActiveState --property=MainPID --property=NRestarts",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout + 1,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {}, str(exc)

    if completed.returncode != 0:
        error = completed.stderr.strip() or f"ssh exit {completed.returncode}"
        return {}, error

    values: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values, None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("server", help="VM1 address or SSH hostname")
    parser.add_argument("--user", required=True, help="SSH user on the responder VM")
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument("--duration", type=float, default=120.0)
    args = parser.parse_args()

    if args.interval <= 0 or args.timeout <= 0 or args.duration <= 0:
        parser.error("interval, timeout and duration must be positive")

    target = f"{args.user}@{args.server}"
    started = time.monotonic()
    previous: tuple[str | None, str | None, str | None] | None = None
    samples = changes = failures = 0

    print(f"monitoring {target} ipsec.service for {args.duration:.1f}s")
    try:
        while time.monotonic() - started < args.duration:
            sample_started = time.monotonic()
            values, error = query(target, args.timeout)
            samples += 1

            if error is not None:
                failures += 1
                print(f"{timestamp()} SSH_ERROR {error}", flush=True)
            else:
                current = (
                    values.get("ActiveState"),
                    values.get("MainPID"),
                    values.get("NRestarts"),
                )
                changed = previous is not None and current != previous
                if changed:
                    changes += 1
                marker = " CHANGE" if changed else ""
                print(
                    f"{timestamp()} active={current[0]} pid={current[1]} "
                    f"restarts={current[2]}{marker}",
                    flush=True,
                )
                previous = current

            elapsed = time.monotonic() - sample_started
            time.sleep(max(0.0, args.interval - elapsed))
    except KeyboardInterrupt:
        print("monitor interrupted", flush=True)

    print(
        f"summary: samples={samples} state_changes={changes} ssh_failures={failures}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
