#!/usr/bin/env python3
"""Find the largest historical Ether.fi oracle-report gaps on Ethereum.

The script uses only Python's standard library and Ethereum JSON-RPC.  It:

* scans ReportPublished and AdminOperationsExecuted logs;
* pairs consensus/publication and execution by report hash;
* decodes accruedRewards from each executeTasks transaction;
* measures the exact reference-slot interval used by the APR guard;
* measures wall-clock execution gaps and consensus-to-execution windows; and
* optionally reads historical LiquidityPool TVL to calculate actual rebase bps.

Example:

    MAINNET_RPC_URL=https://... python3 my-audit/scripts/find_oracle_report_gaps.py

Use --lookback-blocks for a quick smoke test and omit it for the full history.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from typing import Any, Iterable, Optional


ORACLE = "0x57aaf0004c716388b21795431cd7d5f9d3bb6a41"
ADMIN = "0x0ef8fa4760db8f5cd4d993f3e3416f30f942d705"
LIQUIDITY_POOL = "0x308861a430be4cce5502d0a12724771fc6daf216"
BLOCKSCOUT_API = "https://eth.blockscout.com/api"

# keccak256 of the canonical event signatures.
REPORT_PUBLISHED_TOPIC = (
    "0x806d044a61ac7edf13f9a0f3dc1846baec3dd94bddee1c6d9f4e7d4841a546b0"
)
ADMIN_EXECUTED_TOPIC = (
    "0x997abd9d07db6cb25b8542e4fe05ddc887fc249d15d5ec7e3089ff385012bd2f"
)

# getTotalPooledEther()
GET_TOTAL_POOLED_ETHER = "0x37cfdaca"
SECONDS_PER_SLOT = 12
ORACLE_DEPLOYMENT_BLOCK = 18_518_785
MAX_REBASE_INTERVAL_SECONDS = int(365 * 24 * 60 * 60 * 25 / 500)


class RpcError(RuntimeError):
    pass


class Rpc:
    def __init__(self, url: str, timeout: int = 60) -> None:
        self.url = url
        self.timeout = timeout
        self._request_id = 0

    def _post(self, payload: Any) -> Any:
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "Mozilla/5.0 etherfi-gap-scanner/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            if exc.code != 403:
                raise RpcError(str(exc)) from exc
            process = subprocess.run(
                [
                    "curl", "-sS", "--fail-with-body", "-X", "POST", self.url,
                    "-H", "content-type: application/json", "--data-binary", "@-",
                ],
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
            if process.returncode:
                raise RpcError(process.stderr or process.stdout) from exc
            return json.loads(process.stdout)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise RpcError(str(exc)) from exc

    def call(self, method: str, params: list[Any], retries: int = 3) -> Any:
        self._request_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": params,
        }
        for attempt in range(retries):
            try:
                response = self._post(payload)
                if "error" in response:
                    raise RpcError(f"{method}: {response['error']}")
                return response["result"]
            except RpcError:
                if attempt + 1 == retries:
                    raise
                time.sleep(0.5 * (2**attempt))
        raise AssertionError("unreachable")

    def batch(self, calls: list[tuple[str, list[Any]]]) -> list[Any | None]:
        payload = []
        ids = []
        for method, params in calls:
            self._request_id += 1
            ids.append(self._request_id)
            payload.append(
                {
                    "jsonrpc": "2.0",
                    "id": self._request_id,
                    "method": method,
                    "params": params,
                }
            )
        try:
            response = self._post(payload)
            if not isinstance(response, list):
                raise RpcError(f"batch request rejected: {response}")
        except RpcError:
            if len(calls) == 1:
                try:
                    return [self.call(calls[0][0], calls[0][1])]
                except RpcError:
                    return [None]
            middle = len(calls) // 2
            return self.batch(calls[:middle]) + self.batch(calls[middle:])
        by_id = {item.get("id"): item for item in response}
        results: list[Any | None] = []
        for request_id in ids:
            item = by_id.get(request_id, {})
            results.append(None if "error" in item else item.get("result"))
        return results


@dataclass
class Publication:
    report_hash: str
    block_number: int
    log_index: int
    tx_hash: str
    timestamp: int = 0
    consensus_version: int = 0
    ref_slot_from: int = 0
    ref_slot_to: int = 0
    ref_block_from: int = 0
    ref_block_to: int = 0


@dataclass
class Execution:
    report_hash: str
    block_number: int
    log_index: int
    tx_hash: str
    executor: str
    timestamp: int = 0
    publication_block: Optional[int] = None
    publication_timestamp: Optional[int] = None
    ref_slot_from: Optional[int] = None
    ref_slot_to: Optional[int] = None
    accrued_rewards_wei: Optional[int] = None
    protocol_fees_wei: Optional[int] = None
    tvl_before_wei: Optional[int] = None
    reference_gap_seconds: Optional[int] = None
    execution_gap_seconds: Optional[int] = None
    consensus_to_execution_seconds: Optional[int] = None

    @property
    def reward_eth(self) -> Optional[float]:
        if self.accrued_rewards_wei is None:
            return None
        return self.accrued_rewards_wei / 1e18

    @property
    def reward_bps(self) -> Optional[float]:
        if not self.tvl_before_wei or self.accrued_rewards_wei is None:
            return None
        return self.accrued_rewards_wei * 10_000 / self.tvl_before_wei


def chunks(items: list[Any], size: int) -> Iterable[list[Any]]:
    for index in range(0, len(items), size):
        yield items[index : index + size]


def hex_int(value: str) -> int:
    return int(value, 16)


def words(data: str) -> list[int]:
    raw = data.removeprefix("0x")
    if len(raw) % 64:
        raise ValueError("ABI data is not word aligned")
    return [int(raw[index : index + 64], 16) for index in range(0, len(raw), 64)]


def signed_256(value: int) -> int:
    return value - (1 << 256) if value >= (1 << 255) else value


def decode_execute_tasks(calldata: str) -> Optional[dict[str, int]]:
    """Decode the static head of executeTasks(OracleReport).

    OracleReport contains dynamic arrays, so the first ABI word is an offset to
    the tuple.  accruedRewards and protocolFees are words 5 and 6 in its head.
    """
    try:
        raw = bytes.fromhex(calldata.removeprefix("0x"))
        if len(raw) < 4 + 32:
            return None
        tuple_offset = int.from_bytes(raw[4:36], "big")
        base = 4 + tuple_offset
        head = [
            int.from_bytes(raw[base + i * 32 : base + (i + 1) * 32], "big")
            for i in range(11)
        ]
        if any(len(raw[base + i * 32 : base + (i + 1) * 32]) != 32 for i in range(11)):
            return None
        return {
            "consensus_version": head[0],
            "ref_slot_from": head[1],
            "ref_slot_to": head[2],
            "ref_block_from": head[3],
            "ref_block_to": head[4],
            "accrued_rewards_wei": signed_256(head[5]),
            "protocol_fees_wei": signed_256(head[6]),
        }
    except (ValueError, IndexError):
        return None


def deployment_block(rpc: Rpc, address: str, latest: int) -> int:
    """Find the first block at which an address has bytecode."""
    low, high = 0, latest
    while low < high:
        middle = (low + high) // 2
        code = rpc.call("eth_getCode", [address, hex(middle)])
        if code and code != "0x":
            high = middle
        else:
            low = middle + 1
    return low


def logs_adaptive(
    rpc: Rpc, address: str, topic: str, start: int, end: int
) -> list[dict[str, Any]]:
    try:
        return rpc.call(
            "eth_getLogs",
            [
                {
                    "address": address,
                    "fromBlock": hex(start),
                    "toBlock": hex(end),
                    "topics": [topic],
                }
            ],
            retries=2,
        )
    except RpcError:
        if start >= end:
            raise
        middle = (start + end) // 2
        return logs_adaptive(rpc, address, topic, start, middle) + logs_adaptive(
            rpc, address, topic, middle + 1, end
        )


def indexed_logs(
    api_url: str, address: str, topic: str, start: int, end: int
) -> list[dict[str, Any]]:
    query = urllib.parse.urlencode(
        {
            "module": "logs",
            "action": "getLogs",
            "fromBlock": start,
            "toBlock": end,
            "address": address,
            "topic0": topic,
        }
    )
    url = f"{api_url}?{query}"
    request = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "etherfi-gap-scanner/1"}
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError:
        process = subprocess.run(
            ["curl", "-sS", "--fail-with-body", url],
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
        if process.returncode:
            raise RpcError(process.stderr or process.stdout)
        payload = json.loads(process.stdout)
    if payload.get("status") != "1" and payload.get("message") != "No logs found":
        raise RpcError(f"indexed log API rejected query: {payload}")
    return payload.get("result", []) if isinstance(payload.get("result"), list) else []


def scan_logs(
    rpc: Rpc, start: int, end: int, chunk_size: int, indexed_api: Optional[str] = None
) -> tuple[list[Publication], list[Execution]]:
    publications: list[Publication] = []
    executions: list[Execution] = []
    total = max(1, end - start + 1)
    cursor = start
    while cursor <= end:
        chunk_end = min(end, cursor + chunk_size - 1)
        print(
            f"\rScanning blocks {cursor:,}-{chunk_end:,} "
            f"({(chunk_end - start + 1) * 100 / total:5.1f}%)",
            end="",
            file=sys.stderr,
            flush=True,
        )
        if indexed_api:
            with ThreadPoolExecutor(max_workers=2) as pool:
                oracle_future = pool.submit(
                    indexed_logs, indexed_api, ORACLE, REPORT_PUBLISHED_TOPIC, cursor, chunk_end
                )
                admin_future = pool.submit(
                    indexed_logs, indexed_api, ADMIN, ADMIN_EXECUTED_TOPIC, cursor, chunk_end
                )
                oracle_logs = oracle_future.result()
                admin_logs = admin_future.result()
        else:
            oracle_logs = logs_adaptive(
                rpc, ORACLE, REPORT_PUBLISHED_TOPIC, cursor, chunk_end
            )
            admin_logs = logs_adaptive(
                rpc, ADMIN, ADMIN_EXECUTED_TOPIC, cursor, chunk_end
            )

        for log in oracle_logs:
            decoded = words(log["data"])
            if len(decoded) < 5 or len(log["topics"]) < 2:
                continue
            publications.append(
                Publication(
                    report_hash=log["topics"][1].lower(),
                    block_number=hex_int(log["blockNumber"]),
                    log_index=hex_int(log["logIndex"]),
                    tx_hash=log["transactionHash"],
                    timestamp=hex_int(log["timeStamp"]) if log.get("timeStamp") else 0,
                    consensus_version=decoded[0],
                    ref_slot_from=decoded[1],
                    ref_slot_to=decoded[2],
                    ref_block_from=decoded[3],
                    ref_block_to=decoded[4],
                )
            )

        for log in admin_logs:
            if len(log["topics"]) < 3:
                continue
            executions.append(
                Execution(
                    report_hash=log["topics"][2].lower(),
                    block_number=hex_int(log["blockNumber"]),
                    log_index=hex_int(log["logIndex"]),
                    tx_hash=log["transactionHash"],
                    timestamp=hex_int(log["timeStamp"]) if log.get("timeStamp") else 0,
                    executor="0x" + log["topics"][1][-40:],
                )
            )
        cursor = chunk_end + 1
    print(file=sys.stderr)
    publications.sort(key=lambda item: (item.block_number, item.log_index))
    executions.sort(key=lambda item: (item.block_number, item.log_index))
    return publications, executions


def hydrate_blocks(rpc: Rpc, publications: list[Publication], executions: list[Execution]) -> None:
    block_numbers = sorted(
        {item.block_number for item in publications if not item.timestamp}
        | {item.block_number for item in executions if not item.timestamp}
    )
    timestamps: dict[int, int] = {}
    if not block_numbers:
        return
    for group in chunks(block_numbers, 100):
        results = rpc.batch(
            [("eth_getBlockByNumber", [hex(number), False]) for number in group]
        )
        for number, block in zip(group, results):
            if block:
                timestamps[number] = hex_int(block["timestamp"])
    for item in publications:
        item.timestamp = timestamps.get(item.block_number, 0)
    for item in executions:
        item.timestamp = timestamps.get(item.block_number, 0)


def hydrate_transactions(rpc: Rpc, executions: list[Execution]) -> None:
    for group in chunks(executions, 100):
        results = rpc.batch(
            [("eth_getTransactionByHash", [item.tx_hash]) for item in group]
        )
        for execution, transaction in zip(group, results):
            if not transaction:
                continue
            decoded = decode_execute_tasks(transaction.get("input", "0x"))
            if not decoded:
                continue
            execution.ref_slot_from = decoded["ref_slot_from"]
            execution.ref_slot_to = decoded["ref_slot_to"]
            execution.accrued_rewards_wei = decoded["accrued_rewards_wei"]
            execution.protocol_fees_wei = decoded["protocol_fees_wei"]


def hydrate_tvl(rpc: Rpc, executions: list[Execution]) -> None:
    """Best-effort historical TVL reads; silently leaves unsupported rows empty."""
    for group in chunks(executions, 100):
        calls = [
            (
                "eth_call",
                [
                    {"to": LIQUIDITY_POOL, "data": GET_TOTAL_POOLED_ETHER},
                    hex(max(0, item.block_number - 1)),
                ],
            )
            for item in group
        ]
        try:
            results = rpc.batch(calls)
        except RpcError:
            return
        for execution, result in zip(group, results):
            if result and result != "0x":
                execution.tvl_before_wei = hex_int(result)


def pair_and_measure(publications: list[Publication], executions: list[Execution]) -> None:
    by_hash: dict[str, list[Publication]] = defaultdict(list)
    for publication in publications:
        by_hash[publication.report_hash].append(publication)

    for execution in executions:
        candidates = [
            item
            for item in by_hash.get(execution.report_hash, [])
            if item.block_number <= execution.block_number
        ]
        if candidates:
            publication = candidates[-1]
            execution.publication_block = publication.block_number
            execution.publication_timestamp = publication.timestamp
            execution.consensus_to_execution_seconds = max(
                0, execution.timestamp - publication.timestamp
            )
            # Use event metadata if an older calldata layout could not be decoded.
            execution.ref_slot_from = execution.ref_slot_from or publication.ref_slot_from
            execution.ref_slot_to = execution.ref_slot_to or publication.ref_slot_to

    previous: Optional[Execution] = None
    for execution in executions:
        if previous is not None:
            execution.execution_gap_seconds = execution.timestamp - previous.timestamp
            if execution.ref_slot_to is not None and previous.ref_slot_to is not None:
                slots = execution.ref_slot_to - previous.ref_slot_to
                if slots >= 0:
                    execution.reference_gap_seconds = slots * SECONDS_PER_SLOT
        previous = execution


def format_duration(seconds: Optional[int]) -> str:
    if seconds is None:
        return "n/a"
    days, remainder = divmod(seconds, 86_400)
    hours, remainder = divmod(remainder, 3_600)
    minutes, secs = divmod(remainder, 60)
    if days:
        return f"{days}d {hours:02}h {minutes:02}m"
    if hours:
        return f"{hours}h {minutes:02}m {secs:02}s"
    return f"{minutes}m {secs:02}s"


def utc(timestamp: int) -> str:
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def print_rows(title: str, rows: list[Execution], metric: str, top: int) -> None:
    print(f"\n{title}")
    print("=" * len(title))
    print(
        f"{'#':>2}  {'duration':>14}  {'executed UTC':19}  "
        f"{'reward ETH':>14}  {'rebase bps':>11}  transaction"
    )
    for rank, item in enumerate(rows[:top], 1):
        duration = format_duration(getattr(item, metric))
        reward = "n/a" if item.reward_eth is None else f"{item.reward_eth:,.6f}"
        bps = "n/a" if item.reward_bps is None else f"{item.reward_bps:.5f}"
        print(
            f"{rank:>2}  {duration:>14}  {utc(item.timestamp):19}  "
            f"{reward:>14}  {bps:>11}  {item.tx_hash}"
        )


def execution_json(item: Execution) -> dict[str, Any]:
    result = asdict(item)
    result["executed_utc"] = utc(item.timestamp)
    result["reward_eth"] = item.reward_eth
    result["reward_bps"] = item.reward_bps
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--rpc-url",
        default=os.getenv("MAINNET_RPC_URL") or os.getenv("ETH_RPC_URL"),
        help="Ethereum archive RPC URL (or set MAINNET_RPC_URL/ETH_RPC_URL)",
    )
    parser.add_argument("--from-block", type=int, help="first block; default: proxy deployment")
    parser.add_argument("--to-block", type=int, help="last block; default: latest")
    parser.add_argument(
        "--lookback-blocks",
        type=int,
        help="scan only this many recent blocks (quick smoke test)",
    )
    parser.add_argument("--chunk-size", type=int, default=100_000)
    parser.add_argument(
        "--blockscout-logs",
        nargs="?",
        const=BLOCKSCOUT_API,
        help="use Blockscout indexed logs API (optional custom API URL)",
    )
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument(
        "--decode-top-gaps",
        type=int,
        default=0,
        help="decode only N largest reference gaps; 0 decodes every report",
    )
    parser.add_argument(
        "--no-tvl",
        action="store_true",
        help="skip historical TVL calls and rebase-bps calculation",
    )
    parser.add_argument("--json-out", help="write all paired executions to this JSON file")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.rpc_url:
        print("error: provide --rpc-url or set MAINNET_RPC_URL", file=sys.stderr)
        return 2

    rpc = Rpc(args.rpc_url)
    latest = hex_int(rpc.call("eth_blockNumber", []))
    end = args.to_block if args.to_block is not None else latest
    if args.from_block is not None:
        start = args.from_block
    else:
        start = ORACLE_DEPLOYMENT_BLOCK
        print(f"Using known EtherFiOracle proxy deployment block {start:,}", file=sys.stderr)
    if args.lookback_blocks:
        start = max(start, end - args.lookback_blocks + 1)
    if start > end:
        raise SystemExit("from-block is greater than to-block")

    publications, executions = scan_logs(
        rpc, start, end, args.chunk_size, args.blockscout_logs
    )
    if not executions:
        print(f"No executions found in blocks {start:,}-{end:,}.")
        return 0

    hydrate_blocks(rpc, publications, executions)
    pair_and_measure(publications, executions)
    decode_targets = executions
    if args.decode_top_gaps > 0:
        top_candidates = []
        for metric in (
            "reference_gap_seconds",
            "execution_gap_seconds",
            "consensus_to_execution_seconds",
        ):
            top_candidates.extend(
                sorted(
                    [item for item in executions if getattr(item, metric) is not None],
                    key=lambda item: getattr(item, metric) or -1,
                    reverse=True,
                )[: args.decode_top_gaps]
            )
        decode_targets = list({item.tx_hash: item for item in top_candidates}.values())
    hydrate_transactions(rpc, decode_targets)
    if not args.no_tvl:
        hydrate_tvl(rpc, decode_targets)

    paired = [item for item in executions if item.publication_timestamp is not None]
    positive = [
        item
        for item in paired
        if item.accrued_rewards_wei is not None and item.accrued_rewards_wei > 0
    ]
    positive_reference = sorted(
        [item for item in positive if item.reference_gap_seconds is not None],
        key=lambda item: item.reference_gap_seconds or -1,
        reverse=True,
    )
    execution_gaps = sorted(
        [item for item in executions if item.execution_gap_seconds is not None],
        key=lambda item: item.execution_gap_seconds or -1,
        reverse=True,
    )
    consensus_windows = sorted(
        [item for item in paired if item.consensus_to_execution_seconds is not None],
        key=lambda item: item.consensus_to_execution_seconds or -1,
        reverse=True,
    )
    rebases = sorted(
        [item for item in positive if item.reward_bps is not None],
        key=lambda item: item.reward_bps or -1,
        reverse=True,
    )

    print(f"Scanned blocks: {start:,}-{end:,}")
    print(f"Reports published: {len(publications):,}")
    print(f"Reports executed:  {len(executions):,}")
    print(f"Positive reports decoded: {len(positive):,}")
    print(
        "25 bps at the 5% APR bound requires: "
        f"{format_duration(MAX_REBASE_INTERVAL_SECONDS)}"
    )
    reached = [
        item
        for item in positive_reference
        if (item.reference_gap_seconds or 0) >= MAX_REBASE_INTERVAL_SECONDS
    ]
    print(f"Positive historical intervals reaching that duration: {len(reached)}")

    print_rows(
        "Largest positive-report reference intervals (economically relevant)",
        positive_reference,
        "reference_gap_seconds",
        args.top,
    )
    print_rows(
        "Largest wall-clock gaps between executions",
        execution_gaps,
        "execution_gap_seconds",
        args.top,
    )
    print_rows(
        "Largest consensus-to-execution windows",
        consensus_windows,
        "consensus_to_execution_seconds",
        args.top,
    )
    if rebases:
        print_rows(
            "Largest decoded positive rebases by bps",
            rebases,
            "reference_gap_seconds",
            args.top,
        )

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as output:
            json.dump([execution_json(item) for item in executions], output, indent=2)
            output.write("\n")
        print(f"\nWrote {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
