#!/usr/bin/env python3
"""Extract and independently verify Scroll Veda accountant auto-pauses.

The explorer is used only as a log index. Every candidate is verified against
archive state from Scroll JSON-RPC at block-1 and block, so a decoded explorer
label is never trusted as proof that an automatic pause occurred.

Usage:
    python3 scripts/audit/extract_scroll_veda_pauses.py \
        --output my-audit/data/scroll_veda_auto_pauses.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request


ACCOUNTANTS = {
    "liquidETH": "0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198",
    "liquidBTC": "0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0",
    "liquidUSD": "0xc315D6e14DDCDC7407784e2Caf815d131Bc1D3E7",
    "eUSD": "0xEB440B36f61Bf62E0C54C622944545f159C3B790",
}

TOPICS = {
    "ExchangeRateUpdated": "0xa95bc6aba40bbc4d95fc35f118c4cd8b53fc5d5b89ed264002af03503a7a9439",
    "Paused": "0x9e87fac88ff661f02d44f95383c817fece4bce600a3dab7a54406878b965e752",
    "Unpaused": "0xa45f47fdea8a1efdd9029a5691c7f759c32b7c698632b563573e155625d16933",
    "UpperBoundUpdated": "0x67d3a3f6bebb5b894324217d5224ff719d5d95dfc67f1bb2645dddbfcd43cadb",
    "LowerBoundUpdated": "0x76fe3c3557dd03afa5caf76f66f4019444ef3999e784ba08f47a33428fcc64d5",
    "DelayInSecondsUpdated": "0x5f7db254db512f40348d8a7ca15d574c051dfe59c19b47e273d926f2f4318606",
}
TOPIC_NAMES = {value: key for key, value in TOPICS.items()}

# accountantState() selector. The return is a static 12-word tuple matching
# AccountantWithRateProviders.AccountantState.
ACCOUNTANT_STATE_CALLDATA = "0x433255de"
STATE_FIELDS = (
    "payoutAddress",
    "highwaterMark",
    "feesOwedInBase",
    "totalSharesLastUpdate",
    "exchangeRate",
    "allowedExchangeRateChangeUpper",
    "allowedExchangeRateChangeLower",
    "lastUpdateTimestamp",
    "isPaused",
    "minimumUpdateDelayInSeconds",
    "platformFee",
    "performanceFee",
)


def get_json(url: str, retries: int = 5) -> dict:
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "etherfi-audit-extractor/1"})
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except Exception:
            if attempt + 1 == retries:
                raise
            time.sleep(1 << attempt)
    raise AssertionError("unreachable")


def rpc(url: str, method: str, params: list, request_id: int = 1):
    payload = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "etherfi-audit-extractor/1"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.load(response)
    if "error" in body:
        raise RuntimeError(f"RPC {method} failed: {body['error']}")
    return body["result"]


def all_address_logs(explorer: str, address: str) -> list[dict]:
    base = f"{explorer.rstrip('/')}/api/v2/addresses/{address}/logs"
    query: dict[str, int] = {}
    result: list[dict] = []
    while True:
        url = base + ("?" + urllib.parse.urlencode(query) if query else "")
        page = get_json(url)
        result.extend(page["items"])
        query = page.get("next_page_params")
        if not query:
            break
    result.sort(key=lambda log: (int(log["block_number"]), int(log["index"])))
    return result


def words(data: str) -> list[int]:
    raw = data.removeprefix("0x")
    if len(raw) % 64:
        raise ValueError(f"non-word-aligned ABI data: {data}")
    return [int(raw[offset : offset + 64], 16) for offset in range(0, len(raw), 64)]


def state_at(rpc_url: str, accountant: str, block: int) -> dict:
    raw = rpc(
        rpc_url,
        "eth_call",
        [{"to": accountant, "data": ACCOUNTANT_STATE_CALLDATA}, hex(block)],
    )
    values = words(raw)
    if len(values) != len(STATE_FIELDS):
        raise ValueError(f"unexpected accountantState tuple length at block {block}: {len(values)}")
    state = dict(zip(STATE_FIELDS, values))
    state["payoutAddress"] = "0x" + values[0].to_bytes(32, "big")[-20:].hex()
    state["isPaused"] = bool(values[8])
    return state


def event_values(log: dict) -> list[int]:
    return words(log["data"])


def event_name(log: dict) -> str | None:
    topic0 = (log.get("topics") or [None])[0]
    return TOPIC_NAMES.get(topic0.lower()) if topic0 else None


def auto_pause_candidates(logs: list[dict]) -> list[dict]:
    """Find update->unpause pairs with no intervening explicit pause.

    Automatic pausing emits only ExchangeRateUpdated; administrative pause()
    emits Paused(). A later Unpaused() therefore identifies the update that
    set isPaused, subject to archive-state verification below.
    """
    candidates: list[dict] = []
    last_transition: dict | None = None
    for log in logs:
        name = event_name(log)
        if name in ("ExchangeRateUpdated", "Paused", "Unpaused"):
            if name == "Unpaused" and last_transition and event_name(last_transition) == "ExchangeRateUpdated":
                candidates.append({"update": last_transition, "unpause": log})
            last_transition = log
    return candidates


def classify_trigger(old: int, new: int, event_time: int, before: dict) -> tuple[str, dict]:
    upper_limit = old * before["allowedExchangeRateChangeUpper"] // 10_000
    lower_limit = old * before["allowedExchangeRateChangeLower"] // 10_000
    delay_deadline = before["lastUpdateTimestamp"] + before["minimumUpdateDelayInSeconds"]
    causes: list[str] = []
    if event_time < delay_deadline:
        causes.append("minimum-update-delay violation")
    if new > upper_limit:
        causes.append("upper-bound violation")
    if new < lower_limit:
        causes.append("lower-bound violation")
    return (" + ".join(causes) if causes else "other/unresolved"), {
        "upperLimit": upper_limit,
        "lowerLimit": lower_limit,
        "delayDeadline": delay_deadline,
    }


def extract_asset(
    asset: str,
    accountant: str,
    explorer: str,
    rpc_url: str,
    ethereum_explorer: str | None,
) -> dict:
    logs = all_address_logs(explorer, accountant)
    relevant = [log for log in logs if event_name(log)]
    rate_updates = [log for log in relevant if event_name(log) == "ExchangeRateUpdated"]
    ethereum_updates: list[dict] = []
    if ethereum_explorer:
        ethereum_updates = [
            log
            for log in all_address_logs(ethereum_explorer, accountant)
            if event_name(log) == "ExchangeRateUpdated"
        ]
    verified: list[dict] = []
    rejected: list[dict] = []
    for pair in auto_pause_candidates(relevant):
        update = pair["update"]
        block = int(update["block_number"])
        old, new, event_time = event_values(update)
        before = state_at(rpc_url, accountant, block - 1)
        after = state_at(rpc_url, accountant, block)
        proof = {
            "beforePaused": before["isPaused"],
            "afterPaused": after["isPaused"],
            "afterStoredRate": after["exchangeRate"],
        }
        if before["isPaused"] or not after["isPaused"] or after["exchangeRate"] != new:
            rejected.append({"transactionHash": update["transaction_hash"], "block": block, "proof": proof})
            continue
        trigger, thresholds = classify_trigger(old, new, event_time, before)
        unpause = pair["unpause"]
        later_updates = [log for log in rate_updates if int(log["block_number"]) > block]
        next_update = later_updates[0] if later_updates else None
        canonical_matches = [
            log
            for log in ethereum_updates
            if event_values(log)[1] == new and event_values(log)[2] <= event_time
        ]
        canonical = canonical_matches[-1] if canonical_matches else None
        verified.append({
            "asset": asset,
            "accountant": accountant,
            "block": block,
            "timestamp": update["block_timestamp"],
            "transactionHash": update["transaction_hash"],
            "oldRate": old,
            "pausedRate": new,
            "eventTimestamp": event_time,
            "allowedExchangeRateChangeUpper": before["allowedExchangeRateChangeUpper"],
            "allowedExchangeRateChangeLower": before["allowedExchangeRateChangeLower"],
            "minimumUpdateDelayInSeconds": before["minimumUpdateDelayInSeconds"],
            "previousUpdateTimestamp": before["lastUpdateTimestamp"],
            "trigger": trigger,
            "thresholds": thresholds,
            "unpauseBlock": int(unpause["block_number"]),
            "unpauseTimestamp": unpause["block_timestamp"],
            "unpauseTransactionHash": unpause["transaction_hash"],
            "firstSubsequentUpdate": None if not next_update else {
                "block": int(next_update["block_number"]),
                "timestamp": next_update["block_timestamp"],
                "transactionHash": next_update["transaction_hash"],
                "oldRate": event_values(next_update)[0],
                "newRate": event_values(next_update)[1],
                "eventTimestamp": event_values(next_update)[2],
            },
            "matchingCanonicalEthereumUpdate": None if not canonical else {
                "block": int(canonical["block_number"]),
                "timestamp": canonical["block_timestamp"],
                "transactionHash": canonical["transaction_hash"],
                "oldRate": event_values(canonical)[0],
                "newRate": event_values(canonical)[1],
                "eventTimestamp": event_values(canonical)[2],
                "secondsBeforeScrollUpdate": event_time - event_values(canonical)[2],
            },
            "archiveProof": proof,
        })
    return {
        "asset": asset,
        "accountant": accountant,
        "indexedRelevantLogCount": len(relevant),
        "automaticPauses": verified,
        "rejectedHeuristicCandidates": rejected,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", default="https://rpc.scroll.io")
    parser.add_argument("--explorer", default="https://scrollscan.com")
    parser.add_argument("--ethereum-explorer", default="https://eth.blockscout.com")
    parser.add_argument("--skip-ethereum", action="store_true")
    parser.add_argument("--output", help="write JSON to this path; stdout when omitted")
    args = parser.parse_args()

    ethereum_explorer = None if args.skip_ethereum else args.ethereum_explorer
    assets = [
        extract_asset(asset, address, args.explorer, args.rpc_url, ethereum_explorer)
        for asset, address in ACCOUNTANTS.items()
    ]
    output = {
        "chain": "Scroll",
        "rpc": args.rpc_url,
        "explorerLogIndex": args.explorer,
        "canonicalEthereumLogIndex": ethereum_explorer,
        "method": "update->Unpaused heuristic, independently proven with archive accountantState calls",
        "assets": assets,
        "automaticPauseCount": sum(len(item["automaticPauses"]) for item in assets),
    }
    rendered = json.dumps(output, indent=2) + "\n"
    if args.output:
        parent = os.path.dirname(args.output)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as destination:
            destination.write(rendered)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
