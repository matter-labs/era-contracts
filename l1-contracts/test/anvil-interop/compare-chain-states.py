#!/usr/bin/env python3
"""Compare two chain-state directories, ignoring non-deterministic Anvil fields.

With FOUNDRY_PROFILE=anvil-interop (cbor_metadata=false), bytecode and CREATE2
addresses are fully deterministic. The only remaining non-deterministic fields are:
  - Block-level: timestamp, basefee, prevrandao, difficulty
  - Account balances: minor variations from basefee-dependent gas costs
  - blocks/transactions arrays: contain hashes derived from the above

This script compares everything except those known volatile fields.

Usage:
    python3 compare-chain-states.py <committed-dir> <generated-dir>

Exit code 0 if states match, 1 if they differ.
"""

import json
import os
import sys

IGNORED_BLOCK_FIELDS = {"timestamp", "basefee", "difficulty", "prevrandao", "blob_excess_gas_and_price"}

# Maximum allowed balance difference in wei (0.01 ETH) — covers gas cost variations
BALANCE_TOLERANCE_WEI = 10**16


def compare_chain_state(data1: dict, data2: dict, name: str) -> list[str]:
    diffs = []

    # Block: compare only deterministic fields
    if "block" in data1 and "block" in data2:
        for k in set(list(data1["block"].keys()) + list(data2["block"].keys())):
            if k in IGNORED_BLOCK_FIELDS:
                continue
            if data1["block"].get(k) != data2["block"].get(k):
                diffs.append(f"  {name}: block.{k}: {data1['block'].get(k)} != {data2['block'].get(k)}")

    # Accounts
    accs1 = data1.get("accounts", {})
    accs2 = data2.get("accounts", {})

    for addr in sorted(set(accs1.keys()) - set(accs2.keys())):
        diffs.append(f"  {name}: account {addr} missing in generated")
    for addr in sorted(set(accs2.keys()) - set(accs1.keys())):
        diffs.append(f"  {name}: account {addr} missing in committed")

    for addr in sorted(set(accs1.keys()) & set(accs2.keys())):
        a1, a2 = accs1[addr], accs2[addr]

        if a1.get("nonce") != a2.get("nonce"):
            diffs.append(f"  {name}: account {addr} nonce: {a1.get('nonce')} != {a2.get('nonce')}")

        if a1.get("code") != a2.get("code"):
            c1, c2 = a1.get("code", ""), a2.get("code", "")
            if len(c1) != len(c2):
                diffs.append(f"  {name}: account {addr} code length: {len(c1)} != {len(c2)}")
            else:
                pos = next((i for i in range(len(c1)) if c1[i] != c2[i]), None)
                diffs.append(f"  {name}: account {addr} code differs at position {pos}/{len(c1)}")

        s1, s2 = a1.get("storage", {}), a2.get("storage", {})
        if s1 != s2:
            all_slots = sorted(set(list(s1.keys()) + list(s2.keys())))
            diff_slots = [s for s in all_slots if s1.get(s) != s2.get(s)]
            diffs.append(f"  {name}: account {addr} storage differs in {len(diff_slots)} slot(s)")
            for slot in diff_slots[:5]:
                diffs.append(f"    slot {slot}: {s1.get(slot)} != {s2.get(slot)}")

        b1_str, b2_str = a1.get("balance", "0x0"), a2.get("balance", "0x0")
        if b1_str != b2_str:
            try:
                b1 = int(b1_str, 16) if isinstance(b1_str, str) else b1_str
                b2 = int(b2_str, 16) if isinstance(b2_str, str) else b2_str
                if abs(b1 - b2) > BALANCE_TOLERANCE_WEI:
                    diffs.append(f"  {name}: account {addr} balance differs significantly: {b1_str} vs {b2_str}")
            except (ValueError, TypeError):
                diffs.append(f"  {name}: account {addr} balance: {b1_str} != {b2_str}")

    return diffs


def compare_json_files(path1: str, path2: str, name: str) -> list[str]:
    if not os.path.exists(path1):
        return [f"  Missing in committed: {name}"]
    if not os.path.exists(path2):
        return [f"  Missing in generated: {name}"]

    with open(path1) as f:
        data1 = json.load(f)
    with open(path2) as f:
        data2 = json.load(f)

    if name.endswith("addresses.json"):
        if data1 != data2:
            diffs = [f"  {name}: addresses differ"]
            for key in set(list(data1.keys()) + list(data2.keys())):
                if data1.get(key) != data2.get(key):
                    diffs.append(f"    {key}: {data1.get(key)} != {data2.get(key)}")
            return diffs
        return []

    return compare_chain_state(data1, data2, name)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <committed-dir> <generated-dir>")
        sys.exit(2)

    committed_dir, generated_dir = sys.argv[1], sys.argv[2]
    for d in (committed_dir, generated_dir):
        if not os.path.isdir(d):
            print(f"Error: {d} is not a directory")
            sys.exit(2)

    all_diffs = []

    for version_dir in sorted(os.listdir(committed_dir)):
        committed_version = os.path.join(committed_dir, version_dir)
        generated_version = os.path.join(generated_dir, version_dir)

        if not os.path.isdir(committed_version):
            continue
        if not os.path.isdir(generated_version):
            all_diffs.append(f"Missing version directory in generated: {version_dir}")
            continue

        all_files = sorted(set(
            [f for f in os.listdir(committed_version) if f.endswith(".json")] +
            [f for f in os.listdir(generated_version) if f.endswith(".json")]
        ))

        for filename in all_files:
            path1 = os.path.join(committed_version, filename)
            path2 = os.path.join(generated_version, filename)
            all_diffs.extend(compare_json_files(path1, path2, f"{version_dir}/{filename}"))

    if all_diffs:
        print("Chain state differences found:")
        for d in all_diffs:
            print(d)
        sys.exit(1)
    else:
        print("Committed chain states are up to date")
        sys.exit(0)


if __name__ == "__main__":
    main()
