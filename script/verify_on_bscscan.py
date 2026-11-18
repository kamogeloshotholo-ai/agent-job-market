#!/usr/bin/env python3
"""Submit a checked-in standard-JSON build to Etherscan API v2 for BscScan.

The phone deploy page signs the creation bytecode in docs/verify. This script
does not recompile. It matches that bytecode against the contract's creation
transaction, then submits the same standard JSON Foundry emitted, so the
verified bytecode matches byte for byte.

Environment:
  CHAIN_ID            56 or 97
  CONTRACT_ADDRESS    deployed address
  BSCSCAN_API_KEY     Etherscan API v2 key (covers BscScan)
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.etherscan.io/v2/api"
RPC = {
    "56": "https://bsc-dataseed.bnbchain.org",
    "97": "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
}
EXPLORER = {
    "56": "https://bscscan.com/address/",
    "97": "https://testnet.bscscan.com/address/",
}


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_artifacts() -> list[dict]:
    manifest = json.load(open(os.path.join(ROOT, "docs/verify/compiler.json"), encoding="utf-8"))
    artifacts = []
    for entry in manifest["contracts"]:
        creation = open(os.path.join(ROOT, entry["creationBytecode"]), encoding="utf-8").read().strip()
        source = open(os.path.join(ROOT, entry["standardJson"]), encoding="utf-8").read()
        json.loads(source)
        artifacts.append({
            "name": entry["name"],
            "contractname": entry["contractname"],
            "creation": creation.lower().removeprefix("0x"),
            "source": source,
            "compiler": manifest["solcVersion"],
        })
    artifacts.sort(key=lambda item: len(item["creation"]), reverse=True)
    return artifacts


def match_creation(tx_input: str, artifacts: list[dict]) -> tuple[dict, str]:
    raw = tx_input.lower().removeprefix("0x")
    hits = []
    for artifact in artifacts:
        if raw.startswith(artifact["creation"]):
            hits.append((artifact, raw[len(artifact["creation"]):]))
    if len(hits) != 1:
        names = ", ".join(item["name"] for item in artifacts)
        fail(
            "The creation transaction does not start with exactly one checked-in bytecode "
            f"({names}). This address was not deployed from docs/verify."
        )
    return hits[0]


def api_get(chain_id: str, key: str, params: dict) -> dict:
    query = urllib.parse.urlencode({"chainid": chain_id, "apikey": key, **params})
    request = urllib.request.Request(API + "?" + query)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode())


def api_post(chain_id: str, key: str, params: dict) -> dict:
    query = urllib.parse.urlencode({"chainid": chain_id, "apikey": key})
    body = urllib.parse.urlencode(params).encode()
    request = urllib.request.Request(
        API + "?" + query,
        data=body,
        headers={"content-type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read().decode())


def rpc(chain_id: str, method: str, params: list) -> dict:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        RPC[chain_id],
        data=payload,
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.loads(response.read().decode())
    if body.get("error"):
        fail("RPC " + method + " failed: " + json.dumps(body["error"]))
    return body["result"]


def creation_input(chain_id: str, key: str, address: str) -> str:
    created = api_get(chain_id, key, {
        "module": "contract",
        "action": "getcontractcreation",
        "contractaddresses": address,
    })
    if created.get("status") != "1" or not created.get("result"):
        fail("BscScan has no creation transaction yet for " + address + ": " + json.dumps(created))
    tx_hash = created["result"][0]["txHash"]
    print("creation tx", tx_hash)
    transaction = rpc(chain_id, "eth_getTransactionByHash", [tx_hash])
    if not transaction or not transaction.get("input"):
        fail("The creation transaction has no input.")
    return transaction["input"]


def already_verified(payload: dict) -> bool:
    text = (str(payload.get("result", "")) + " " + str(payload.get("message", ""))).lower()
    return "already verified" in text


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        artifacts = load_artifacts()
        chosen = artifacts[-1]
        matched, args = match_creation("0x" + chosen["creation"] + "abcdef", artifacts)
        if matched["name"] != chosen["name"] or args != "abcdef":
            fail("self-test mismatch")
        print("self-test ok", matched["name"])
        return

    chain_id = os.environ.get("CHAIN_ID", "").strip()
    address = os.environ.get("CONTRACT_ADDRESS", "").strip()
    key = os.environ.get("BSCSCAN_API_KEY", "").strip()
    if chain_id not in RPC:
        fail("CHAIN_ID must be 56 or 97.")
    if not address.startswith("0x") or len(address) != 42:
        fail("CONTRACT_ADDRESS must be a 0x address.")
    if not key:
        fail("BSCSCAN_API_KEY is empty. Add it as a repository secret.")

    artifacts = load_artifacts()
    tx_input = creation_input(chain_id, key, address)
    artifact, constructor_args = match_creation(tx_input, artifacts)
    print("matched", artifact["contractname"])
    print("constructor args bytes", len(constructor_args) // 2)

    submitted = api_post(chain_id, key, {
        "module": "contract",
        "action": "verifysourcecode",
        "contractaddress": address,
        "sourceCode": artifact["source"],
        "codeformat": "solidity-standard-json-input",
        "contractname": artifact["contractname"],
        "compilerversion": artifact["compiler"],
        "constructorArguements": constructor_args,
    })
    print(json.dumps(submitted))
    if already_verified(submitted):
        print("Already verified:", EXPLORER[chain_id] + address)
        return
    if submitted.get("status") != "1":
        fail("BscScan rejected the verification: " + json.dumps(submitted))

    guid = submitted["result"]
    for _ in range(24):
        time.sleep(5)
        status = api_get(chain_id, key, {
            "module": "contract",
            "action": "checkverifystatus",
            "guid": guid,
        })
        print(json.dumps(status))
        result = str(status.get("result", ""))
        if result.startswith("Pass") or "successfully" in result.lower() or already_verified(status):
            print("Verified:", EXPLORER[chain_id] + address)
            return
        if result.startswith("Fail") or (status.get("status") == "0" and "pending" not in result.lower()):
            fail("Verification failed: " + result)
    fail("Verification is still pending. Check the GUID " + guid + " on BscScan.")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        fail("HTTP " + str(error.code) + " from the explorer API: " + error.read().decode()[:500])
    except urllib.error.URLError as error:
        fail("Network error: " + str(error.reason))
