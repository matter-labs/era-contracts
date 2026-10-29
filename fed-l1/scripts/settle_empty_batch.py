#!/usr/bin/env python3
"""Reference settlement of batches 1 and 2 on the deployed chains, with `cast` only.

It exercises exactly the encodings README.md documents, computing the batch commitment locally
(and checking it against the BlockCommit event), so the host can diff its own encoder against it:

  batch 1: no L1 txs (the allowInteropPeer service tx stays queued) and carries the genesis
           system-upgrade tx hash in its batch output hash;
  batch 2: consumes priority op #0 (the allowInteropPeer service tx), with a Merkle proof
           against the priority tree.

State roots are dummies (the batch keeps the genesis state commitment); proofs are the type-3
mock proof the MultiProofTestnetVerifier accepts. deploy.sh runs this inside evm_snapshot /
evm_revert, so the chains are left at batch 0.

Usage: settle_empty_batch.py --rpc URL --addresses out/addresses.json --chain 301 [--chain 302]
"""
import argparse
import json
import subprocess

EMPTY_STRING_KECCAK = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
ZERO32 = "0x" + "00" * 32
SBI = "(uint64,bytes32,uint64,uint256,bytes32,bytes32,bytes32,uint256,bytes32)"
CBI = ("(uint64,bytes32,uint256,uint256,bytes32,bytes32,bytes32,uint8,bytes32,"
       "uint64,uint64,uint64,uint64,uint256,bytes,uint256,bytes32,uint256)")
PRIO = "(bytes32[],bytes32[],bytes32[])"
IROOT = "(uint256,uint256,uint256,bytes32[])"
COMMIT_VERSION, PROOF_VERSION, EXECUTE_VERSION = 6, 1, 2
EMPTY_NO_DA = 1


def cast(*args):
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"cast {' '.join(args[:3])} ... failed:\n{r.stderr}")
    return r.stdout.strip()


def keccak(hexdata):
    return cast("keccak", hexdata)


def h(x, n=32):
    """big-endian hex of an int / hex string, n bytes, no 0x"""
    if isinstance(x, str):
        x = int(x, 16)
    return format(x, f"0{2 * n}x")


def tup(values):
    return "(" + ",".join(str(v) for v in values) + ")"


def arr(items):
    return "[" + ",".join(items) + "]"


def stored_tuple(b):
    return tup([b["batchNumber"], b["batchHash"], b["indexRepeatedStorageChanges"], b["numberOfLayer1Txs"],
                b["priorityOperationsHash"], b["dependencyRootsRollingHash"], b["l2LogsTreeRoot"],
                b["timestamp"], b["commitment"]])


def rolling_hash(items):
    acc = EMPTY_STRING_KECCAK
    for it in items:
        acc = keccak("0x" + h(acc) + h(it))
    return acc


def batch_output_hash(nb, upgrade_tx_hash):
    # Committer._getBatchOutputHash: abi.encodePacked, uint64 fields are 8 bytes.
    packed = (h(nb["firstBlockTimestamp"], 8) + h(nb["lastBlockTimestamp"], 8) + h(nb["daCommitmentScheme"])
              + h(nb["daCommitment"]) + h(nb["numberOfLayer1Txs"]) + h(nb["numberOfLayer2Txs"])
              + h(nb["priorityOperationsHash"]) + h(nb["l2LogsTreeRoot"]) + h(upgrade_tx_hash)
              + h(nb["dependencyRootsRollingHash"]) + h(nb["slChainId"]) + h(nb["interopFeeUnits"]))
    return keccak("0x" + packed)


def settle(rpc, chain, timelock, prev, l1_txs, upgrade_tx_hash, sl_chain_id):
    dp, pk, cid = chain["diamond_proxy"], chain["operator_private_key"], chain["chain_id"]
    n = prev["batchNumber"] + 1
    ts = int(json.loads(cast("block", "--rpc-url", rpc, "latest", "--json"))["timestamp"], 16)
    prio_hash = rolling_hash(l1_txs)
    nb = {
        "batchNumber": n,
        "newStateCommitment": prev["batchHash"],  # dummy: state unchanged
        "numberOfLayer1Txs": len(l1_txs),
        "numberOfLayer2Txs": 0,
        "priorityOperationsHash": prio_hash,
        "dependencyRootsRollingHash": ZERO32,
        "l2LogsTreeRoot": chain["genesis_chain_batch_root"],  # any non-zero root is accepted by MessageRoot
        "daCommitmentScheme": EMPTY_NO_DA,
        "daCommitment": ZERO32,
        "firstBlockTimestamp": ts,
        "firstBlockNumber": n,
        "lastBlockTimestamp": ts,
        "lastBlockNumber": n,
        "chainId": cid,
        "operatorDAInput": ZERO32,  # ValidiumL1DAValidator: exactly 32 bytes, unchecked
        "slChainId": sl_chain_id,
        "chainConfigHash": chain["zksync_os_chain_config_hash"],
        "interopFeeUnits": 0,
    }
    commitment = keccak("0x" + h(prev["batchHash"]) + h(nb["newStateCommitment"]) + h(nb["chainConfigHash"])
                        + h(batch_output_hash(nb, upgrade_tx_hash)))

    commit_data = "0x%02x" % COMMIT_VERSION + cast(
        "abi-encode", f"f({SBI},{CBI}[])", stored_tuple(prev), arr([tup(nb.values())]))[2:]
    rcpt = json.loads(cast("send", "--rpc-url", rpc, "--private-key", pk, "--json", timelock,
                           "commitBatchesSharedBridge(address,uint256,uint256,bytes)", dp, str(n), str(n), commit_data))
    topic = keccak("0x" + "BlockCommit(uint256,bytes32,bytes32)".encode().hex())
    ev = [l for l in rcpt["logs"] if l["address"].lower() == dp.lower() and l["topics"][0] == topic]
    assert len(ev) == 1, "expected one BlockCommit"
    assert ev[0]["topics"][3] == commitment, f"commitment mismatch: local {commitment} event {ev[0]['topics'][3]}"

    stored = {"batchNumber": n, "batchHash": nb["newStateCommitment"], "indexRepeatedStorageChanges": 0,
              "numberOfLayer1Txs": len(l1_txs), "priorityOperationsHash": prio_hash,
              "dependencyRootsRollingHash": ZERO32, "l2LogsTreeRoot": nb["l2LogsTreeRoot"], "timestamp": 0,
              "commitment": commitment}
    onchain = cast("call", "--rpc-url", rpc, dp, "storedBatchHash(uint256)(bytes32)", str(n))
    assert keccak(cast("abi-encode", f"f({SBI})", stored_tuple(stored))) == onchain, "stored batch hash mismatch"

    # Mock proof [type=3, 0, magic=13, commitment >> 32] (MultiProofTestnetVerifier._mockVerify).
    proof = arr(["3", "0", "13", str(int(commitment, 16) >> 32)])
    proof_data = "0x%02x" % PROOF_VERSION + cast(
        "abi-encode", f"f({SBI},{SBI}[],uint256[])", stored_tuple(prev), arr([stored_tuple(stored)]), proof)[2:]
    cast("send", "--rpc-url", rpc, "--private-key", pk, timelock,
         "proveBatchesSharedBridge(address,uint256,uint256,bytes)", dp, str(n), str(n), proof_data)

    # Priority ops proof: the queue holds exactly one leaf here, so the tree has height 0 and both
    # paths are empty (Merkle.calculateRootPaths allows that for start 0 with one item).
    prio_info = tup([arr([]), arr([]), arr(l1_txs)])
    execute_data = "0x%02x" % EXECUTE_VERSION + cast(
        "abi-encode", f"f(({SBI}[],{PRIO}[],{IROOT}[][]))",
        tup([arr([stored_tuple(stored)]), arr([prio_info]), arr([arr([])])]))[2:]
    cast("send", "--rpc-url", rpc, "--private-key", pk, timelock,
         "executeBatchesSharedBridge(address,uint256,uint256,bytes)", dp, str(n), str(n), execute_data)

    executed = int(cast("call", "--rpc-url", rpc, dp, "getTotalBatchesExecuted()(uint256)").split(" ")[0])
    assert executed == n, f"executed {executed} != {n}"
    print(f"  chain {cid}: batch {n} committed/proven/executed (L1 txs: {len(l1_txs)}, commitment {commitment})")
    return stored


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--addresses", required=True)
    ap.add_argument("--chain", action="append", required=True)
    a = ap.parse_args()
    addrs = json.load(open(a.addresses))
    timelock = addrs["contracts"]["validator_timelock"]
    sl = addrs["l1"]["chain_id"]
    for cid in a.chain:
        c = addrs["chains"][cid]
        b0 = c["genesis_stored_batch_info"]
        b1 = settle(a.rpc, c, timelock, b0, [], c["l2_system_contracts_upgrade_tx_hash"], sl)
        up = cast("call", "--rpc-url", a.rpc, c["diamond_proxy"], "getL2SystemContractsUpgradeTxHash()(bytes32)")
        assert up == ZERO32, "upgrade tx hash not cleared after batch 1"
        pending = [p["canonical_tx_hash"] for p in c["priority_queue"]["pending"]]
        settle(a.rpc, c, timelock, b1, pending, ZERO32, sl)
        mr = addrs["contracts"]["message_root"]
        root = cast("call", "--rpc-url", a.rpc, mr, "chainBatchRoots(uint256,uint256)(bytes32)", cid, "2")
        assert root == c["genesis_chain_batch_root"], "chain batch root of batch 2 not recorded"


if __name__ == "__main__":
    main()
