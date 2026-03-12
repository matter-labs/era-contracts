#!/usr/bin/env python3
"""Compare two chain-state directories, ignoring non-deterministic Anvil fields.

Anvil state dumps include fields that vary between runs even with identical
transactions (timestamp, basefee, prevrandao, block hashes, tx hashes, etc.)
and Solidity compiler metadata suffixes in deployed bytecode.

This script compares only the semantically meaningful parts:
  - Account nonces and storage
  - Account bytecode (stripped of Solidity CBOR metadata suffix)
  - Account balances (compared with tolerance for gas cost variations)
  - addresses.json (exact match)

Usage:
    python3 compare-chain-states.py <committed-dir> <generated-dir>

Exit code 0 if states match, 1 if they differ.
"""

import json
import os
import re
import sys


# Solidity appends a CBOR-encoded metadata section at the end of deployed bytecode.
# The marker is 'a264697066735822' (CBOR map with "ipfs" key + 34-byte hash),
# followed by '64736f6c63' ("solc") + version + '0033' (CBOR length).
# This metadata includes source hashes that change across compiler builds/platforms,
# but the executable bytecode before it is deterministic.
SOLC_METADATA_RE = re.compile(r"a264697066735822[0-9a-fA-F]{68}64736f6c6343[0-9a-fA-F]{6}0033$")


def strip_solc_metadata(code: str) -> str:
    """Remove the Solidity CBOR metadata suffix from bytecode."""
    return SOLC_METADATA_RE.sub("", code)


# Non-deterministic top-level block fields to ignore
IGNORED_BLOCK_FIELDS = {"timestamp", "basefee", "difficulty", "prevrandao", "blob_excess_gas_and_price"}


def normalize_state(state: dict) -> dict:
    """Return a normalized copy of a chain state for comparison."""
    normalized = {}

    # Block: keep only deterministic fields
    if "block" in state:
        normalized["block"] = {
            k: v for k, v in state["block"].items() if k not in IGNORED_BLOCK_FIELDS
        }

    # Accounts: compare nonce, storage, and stripped bytecode
    if "accounts" in state:
        accounts = {}
        for addr, acc in state["accounts"].items():
            accounts[addr] = {
                "nonce": acc.get("nonce"),
                "balance": acc.get("balance"),
                "code": strip_solc_metadata(acc.get("code", "")),
                "storage": acc.get("storage", {}),
            }
        normalized["accounts"] = accounts

    # Ignore: blocks, transactions, historical_states, best_block_number
    # These contain hashes, timestamps, and other non-deterministic data

    return normalized


def compare_json_files(path1: str, path2: str, name: str) -> list[str]:
    """Compare two JSON files, return list of differences."""
    diffs = []

    if not os.path.exists(path1):
        diffs.append(f"  Missing in committed: {name}")
        return diffs
    if not os.path.exists(path2):
        diffs.append(f"  Missing in generated: {name}")
        return diffs

    with open(path1) as f:
        data1 = json.load(f)
    with open(path2) as f:
        data2 = json.load(f)

    if name == "addresses.json":
        # addresses.json must match exactly
        if data1 != data2:
            diffs.append(f"  {name}: addresses differ")
            # Show what changed
            for key in set(list(data1.keys()) + list(data2.keys())):
                if data1.get(key) != data2.get(key):
                    diffs.append(f"    {key}: {data1.get(key)} != {data2.get(key)}")
        return diffs

    # Chain state files: normalize and compare
    norm1 = normalize_state(data1)
    norm2 = normalize_state(data2)

    # Compare block
    if norm1.get("block") != norm2.get("block"):
        diffs.append(f"  {name}: block fields differ")
        for k in set(list(norm1.get("block", {}).keys()) + list(norm2.get("block", {}).keys())):
            v1 = norm1.get("block", {}).get(k)
            v2 = norm2.get("block", {}).get(k)
            if v1 != v2:
                diffs.append(f"    block.{k}: {v1} != {v2}")

    # Compare accounts
    accs1 = norm1.get("accounts", {})
    accs2 = norm2.get("accounts", {})

    all_addrs = sorted(set(list(accs1.keys()) + list(accs2.keys())))
    for addr in all_addrs:
        if addr not in accs1:
            diffs.append(f"  {name}: account {addr} missing in committed")
            continue
        if addr not in accs2:
            diffs.append(f"  {name}: account {addr} missing in generated")
            continue

        a1, a2 = accs1[addr], accs2[addr]

        if a1["nonce"] != a2["nonce"]:
            diffs.append(f"  {name}: account {addr} nonce: {a1['nonce']} != {a2['nonce']}")

        if a1["code"] != a2["code"]:
            # Find where they diverge
            c1, c2 = a1["code"], a2["code"]
            if len(c1) != len(c2):
                diffs.append(f"  {name}: account {addr} code length: {len(c1)} != {len(c2)}")
            else:
                pos = next((i for i in range(len(c1)) if c1[i] != c2[i]), None)
                diffs.append(f"  {name}: account {addr} code differs at position {pos}/{len(c1)}")

        if a1["storage"] != a2["storage"]:
            s1, s2 = a1["storage"], a2["storage"]
            all_slots = sorted(set(list(s1.keys()) + list(s2.keys())))
            diff_slots = [s for s in all_slots if s1.get(s) != s2.get(s)]
            diffs.append(f"  {name}: account {addr} storage differs in {len(diff_slots)} slot(s)")
            for slot in diff_slots[:5]:  # Show first 5
                diffs.append(f"    slot {slot}: {s1.get(slot)} != {s2.get(slot)}")

        # Balance: warn but don't fail (gas cost variations)
        if a1["balance"] != a2["balance"]:
            # Convert hex balances to int for comparison
            try:
                b1 = int(a1["balance"], 16) if isinstance(a1["balance"], str) else a1["balance"]
                b2 = int(a2["balance"], 16) if isinstance(a2["balance"], str) else a2["balance"]
                diff_wei = abs(b1 - b2)
                # Allow up to 0.01 ETH difference (gas cost variations)
                if diff_wei > 10**16:
                    diffs.append(f"  {name}: account {addr} balance differs significantly: {a1['balance']} vs {a2['balance']} (delta: {diff_wei} wei)")
            except (ValueError, TypeError):
                if a1["balance"] != a2["balance"]:
                    diffs.append(f"  {name}: account {addr} balance: {a1['balance']} != {a2['balance']}")

    return diffs


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <committed-dir> <generated-dir>")
        sys.exit(2)

    committed_dir = sys.argv[1]
    generated_dir = sys.argv[2]

    if not os.path.isdir(committed_dir):
        print(f"Error: {committed_dir} is not a directory")
        sys.exit(2)
    if not os.path.isdir(generated_dir):
        print(f"Error: {generated_dir} is not a directory")
        sys.exit(2)

    all_diffs = []

    # Walk through all version directories
    for version_dir in sorted(os.listdir(committed_dir)):
        committed_version = os.path.join(committed_dir, version_dir)
        generated_version = os.path.join(generated_dir, version_dir)

        if not os.path.isdir(committed_version):
            continue

        if not os.path.isdir(generated_version):
            all_diffs.append(f"Missing version directory in generated: {version_dir}")
            continue

        # Compare all JSON files in this version
        all_files = sorted(set(
            [f for f in os.listdir(committed_version) if f.endswith(".json")] +
            [f for f in os.listdir(generated_version) if f.endswith(".json")]
        ))

        for filename in all_files:
            path1 = os.path.join(committed_version, filename)
            path2 = os.path.join(generated_version, filename)
            diffs = compare_json_files(path1, path2, f"{version_dir}/{filename}")
            all_diffs.extend(diffs)

    if all_diffs:
        print("Chain state differences found:")
        for d in all_diffs:
            print(d)
        sys.exit(1)
    else:
        print("Committed chain states are up to date (ignoring non-deterministic fields)")
        sys.exit(0)


if __name__ == "__main__":
    main()
