#!/usr/bin/env python3
"""Bounded TCP/4500 availability monitor for the CVE-2026-94453 VM lab.

This measures whether Pluto's TCP listener accepts connections.  It does not
establish an IKE/IPsec SA and therefore is not a full VPN health check.
"""

import argparse
import signal
import socket
import time
from datetime import datetime


# When output is piped through tee, Ctrl-C may close the reader before Python
# flushes its final summary.  Exit quietly instead of printing BrokenPipeError.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("server", help="Pluto server address")
    parser.add_argument("--port", type=int, default=4500)
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=0.20)
    parser.add_argument(
        "--duration",
        type=float,
        default=180.0,
        help="maximum test duration in seconds (default: 180)",
    )
    args = parser.parse_args()

    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    if args.interval <= 0 or args.timeout <= 0 or args.duration <= 0:
        parser.error("interval, timeout and duration must be positive")

    started = time.monotonic()
    total = up = down = 0
    current_down_streak = longest_down_streak = 0
    previous = None

    print(
        f"monitoring {args.server}:{args.port} every {args.interval:.2f}s "
        f"for at most {args.duration:.1f}s"
    )

    try:
        while time.monotonic() - started < args.duration:
            attempt_started = time.monotonic()
            error = None
            try:
                with socket.create_connection(
                    (args.server, args.port), timeout=args.timeout
                ):
                    available = True
            except OSError as exc:
                available = False
                error = exc

            latency_ms = (time.monotonic() - attempt_started) * 1000
            total += 1
            if available:
                up += 1
                current_down_streak = 0
                status = f"UP latency_ms={latency_ms:.2f}"
            else:
                down += 1
                current_down_streak += 1
                longest_down_streak = max(
                    longest_down_streak, current_down_streak
                )
                status = f"DOWN error={error}"

            marker = " transition" if previous is not None and previous != available else ""
            print(f"{timestamp()} {status}{marker}", flush=True)
            previous = available

            elapsed = time.monotonic() - attempt_started
            time.sleep(max(0.0, args.interval - elapsed))
    except KeyboardInterrupt:
        print("monitor interrupted", flush=True)

    elapsed = time.monotonic() - started
    availability = 100.0 * up / total if total else 0.0
    approximate_longest_outage = longest_down_streak * args.interval
    print(
        "summary: "
        f"elapsed={elapsed:.2f}s probes={total} up={up} down={down} "
        f"availability={availability:.3f}% "
        f"longest_observed_outage~={approximate_longest_outage:.2f}s"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
