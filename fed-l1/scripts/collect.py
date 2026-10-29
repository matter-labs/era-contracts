#!/usr/bin/env python3
"""Reads the deployed state back from anvil (via `cast`) and writes fed-l1/out/addresses.json.

Everything per-chain is read from the chain itself, so the file reflects what the contracts store,
not what the deploy scripts intended. Called by deploy.sh.
"""
import argparse
import json
import os
import subprocess

L1C = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "l1-contracts")

EMPTY_STRING_KECCAK = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
DEFAULT_L2_LOGS_TREE_ROOT_HASH = "0x" + "00" * 32
GENESIS_BATCH_COMMITMENT = "0x" + "00" * 31 + "01"
STORED_BATCH_INFO = "(uint64,bytes32,uint64,uint256,bytes32,bytes32,bytes32,uint256,bytes32)"


def cast(*args):
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


def call(rpc, to, sig, *args):
    """Single-value calls are normalized: uints -> str of the decimal (cast's " [1e21]" hint dropped),
    bools -> bool. Multi-value calls return cast's raw multi-line output."""
    out = cast("call", "--rpc-url", rpc, to, sig, *args)
    if "\n" in out:
        return out
    out = out.split(" ")[0]
    if out in ("true", "false"):
        return out == "true"
    return out


def lines(s):
    return [l.split(" ")[0] for l in s.splitlines()]


def canonical_type(inp):
    t = inp["type"]
    if t.startswith("tuple"):
        return "(" + ",".join(canonical_type(c) for c in inp["components"]) + ")" + t[len("tuple"):]
    return t


def event_sig(artifact, name):
    abi = json.load(open(os.path.join(L1C, "out", artifact, artifact.replace(".sol", "") + ".json")))["abi"]
    ev = next(e for e in abi if e.get("type") == "event" and e["name"] == name)
    return f'{name}({",".join(canonical_type(i) for i in ev["inputs"])})'


def logs(rpc, address, signature):
    out = cast("logs", "--rpc-url", rpc, "--from-block", "0", "--address", address, signature, "--json")
    return json.loads(out or "[]")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--l1-chain-id", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True, help="dir with the forge script outputs (chain-<id>-output.toml)")
    ap.add_argument("--set", nargs="*", default=[])
    ap.add_argument("--chain", nargs=3, action="append", metavar=("ID", "OPERATOR", "OPERATOR_PK"), default=[])
    a = ap.parse_args()
    rpc = a.rpc

    top = dict(kv.split("=", 1) for kv in a.set)
    res = {
        "l1": {"rpc_url": rpc, "chain_id": a.l1_chain_id},
        "contracts": {},
        "tokens": {},
        "accounts": {},
        "chains": {},
    }
    for k in ["bridgehub", "message_root", "l1_asset_router", "l1_native_token_vault", "l1_nullifier",
              "l1_interop_handler", "chain_registration_sender", "chain_asset_handler", "governance",
              "bridgehub_admin", "chain_type_manager", "ctm_release", "validator_timelock",
              "validium_l1_da_validator"]:
        res["contracts"][k] = top[k]
    res["contracts"]["l1_interop_handler_from_asset_router"] = call(rpc, top["l1_asset_router"], "l1InteropHandler()(address)")
    res["tokens"] = {
        "eth": {"address": "0x0000000000000000000000000000000000000001", "asset_id": top["eth_asset_id"]},
        "usdc": {"address": top["usdc"], "asset_id": top["usdc_asset_id"], "decimals": 18, "symbol": "USDC"},
        "dai": {"address": top["dai"], "asset_id": top["dai_asset_id"], "decimals": 18, "symbol": "DAI"},
        "zk": {"address": top["zk_token"], "asset_id": top["zk_token_asset_id"],
               "note": "only used as the CTM's zk_token_asset_id; not registered in the NTV"},
    }
    res["accounts"] = {
        "deployer": {"address": top["deployer"], "private_key": top["deployer_private_key"],
                     "roles": "owner of Bridgehub/NTV/MessageRoot/ChainRegistrationSender/CTM/ValidatorTimelock, "
                              "admin of both chain diamonds, Governance owner"},
        "alice": {"address": top["alice"], "private_key": top["alice_private_key"]},
        "bob": {"address": top["bob"], "private_key": top["bob_private_key"]},
    }
    for who in ("alice", "bob"):
        acc = res["accounts"][who]
        acc["eth_balance_wei"] = cast("balance", "--rpc-url", rpc, acc["address"])
        acc["usdc_balance"] = call(rpc, top["usdc"], "balanceOf(address)(uint256)", acc["address"])
        acc["dai_balance"] = call(rpc, top["dai"], "balanceOf(address)(uint256)", acc["address"])

    bh, mr, crs = top["bridgehub"], top["message_root"], top["chain_registration_sender"]
    ntv = top["l1_native_token_vault"]
    _, genesis_batch_hash, genesis_index = lines(call(rpc, top["ctm_release"], "genesisParams()(address,bytes32,uint64)"))
    res["ctm_genesis"] = {
        "genesis_batch_hash": genesis_batch_hash,
        "genesis_index_repeated_storage_changes": int(genesis_index),
        "genesis_batch_commitment": GENESIS_BATCH_COMMITMENT,
        "stored_batch_zero_hash": call(rpc, top["chain_type_manager"], "storedBatchZero()(bytes32)"),
    }
    sig_prio = event_sig("IMailbox.sol", "NewPriorityRequest")
    sig_genesis = event_sig("IL1GenesisUpgrade.sol", "GenesisUpgrade")
    chain_ids = [int(c[0]) for c in a.chain]

    for cid_s, operator, operator_pk in a.chain:
        cid = int(cid_s)
        dp = call(rpc, bh, "getZKChain(uint256)(address)", cid_s)
        out_toml = open(os.path.join(a.work, f"chain-{cid}-output.toml")).read()

        def toml_val(key):
            for l in out_toml.splitlines():
                if l.strip().startswith(key + " "):
                    return l.split("=", 1)[1].strip().strip('"')
            return None

        batch0 = {
            "batchNumber": 0,
            "batchHash": genesis_batch_hash,
            "indexRepeatedStorageChanges": int(genesis_index),
            "numberOfLayer1Txs": 0,
            "priorityOperationsHash": EMPTY_STRING_KECCAK,
            "dependencyRootsRollingHash": "0x" + "00" * 32,
            "l2LogsTreeRoot": DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            "timestamp": 0,
            "commitment": GENESIS_BATCH_COMMITMENT,
        }
        tup = "(" + ",".join(str(v) for v in batch0.values()) + ")"
        computed = cast("keccak", cast("abi-encode", f"f({STORED_BATCH_INFO})", tup))
        stored = call(rpc, dp, "storedBatchHash(uint256)(bytes32)", "0")
        if computed != stored:
            raise SystemExit(f"chain {cid}: rebuilt batch 0 hashes to {computed}, chain stores {stored}")

        prio = []
        for lg in logs(rpc, dp, sig_prio):
            data = lg["data"][2:]
            prio.append({
                "tx_id": int(data[0:64], 16),
                "canonical_tx_hash": "0x" + data[64:128],
                "l1_block_number": int(lg["blockNumber"], 16),
                "l1_tx_hash": lg["transactionHash"],
                "log_data": lg["data"],
            })
        gen = logs(rpc, dp, sig_genesis)
        upgrade_tx_hash = call(rpc, dp, "getL2SystemContractsUpgradeTxHash()(bytes32)")
        da = lines(call(rpc, dp, "getDAValidatorPair()(address,uint8)"))
        semver = lines(call(rpc, dp, "getSemverProtocolVersion()(uint32,uint32,uint32)"))

        res["chains"][str(cid)] = {
            "chain_id": cid,
            "diamond_proxy": dp,
            "chain_type_manager": call(rpc, bh, "chainTypeManager(uint256)(address)", cid_s),
            "chain_admin": call(rpc, dp, "getAdmin()(address)"),
            "chain_pending_admin": call(rpc, dp, "getPendingAdmin()(address)"),
            "chain_admin_ownable_contract": toml_val("chain_admin_addr"),
            "chain_governance": toml_val("governance_addr"),
            "operator": operator,
            "operator_private_key": operator_pk,
            "operator_note": "holds committer/prover/executor/reverter roles on validator_timelock; call "
                             "ValidatorTimelock.{commit,prove,execute}BatchesSharedBridge(diamond_proxy, from, to, data)",
            "validator_timelock": top["validator_timelock"],
            "timelock_is_validator_on_diamond": call(rpc, dp, "isValidator(address)(bool)", top["validator_timelock"]),
            "base_token_asset_id": call(rpc, bh, "baseTokenAssetId(uint256)(bytes32)", cid_s),
            "settlement_layer": int(call(rpc, bh, "settlementLayer(uint256)(uint256)", cid_s)),
            "protocol_version": int(call(rpc, dp, "getProtocolVersion()(uint256)")),
            "protocol_semver": ".".join(semver),
            "verifier": call(rpc, dp, "getVerifier()(address)"),
            "proof_mode": int(call(rpc, dp, "getProofMode()(uint256)")),
            "second_proof_system_required": call(rpc, dp, "isSecondProofSystemRequired()(bool)"),
            "da_validator_pair": {"l1_da_validator": da[0], "l2_da_commitment_scheme": int(da[1]),
                                  "scheme_name": "EMPTY_NO_DA" if da[1] == "1" else da[1]},
            "zksync_os_chain_config_hash": call(rpc, dp, "getZKsyncOSChainConfigHash()(bytes32)"),
            "total_batches_committed": int(call(rpc, dp, "getTotalBatchesCommitted()(uint256)")),
            "total_batches_verified": int(call(rpc, dp, "getTotalBatchesVerified()(uint256)")),
            "total_batches_executed": int(call(rpc, dp, "getTotalBatchesExecuted()(uint256)")),
            "genesis_stored_batch_info": batch0,
            "genesis_stored_batch_hash": stored,
            "genesis_chain_batch_root": call(rpc, dp, "l2LogsRootHash(uint256)(bytes32)", "0"),
            "l2_system_contracts_upgrade_tx_hash": upgrade_tx_hash,
            "genesis_upgrade_event": {
                "l1_block_number": int(gen[0]["blockNumber"], 16),
                "l1_tx_hash": gen[0]["transactionHash"],
                "event_signature": sig_genesis,
                "log_data": gen[0]["data"],
            } if gen else None,
            "priority_queue": {
                "total_priority_txs": int(call(rpc, dp, "getTotalPriorityTxs()(uint256)")),
                "first_unprocessed": int(call(rpc, dp, "getFirstUnprocessedPriorityTx()(uint256)")),
                "tree_start_index": int(call(rpc, dp, "getPriorityTreeStartIndex()(uint256)")),
                "tree_root": call(rpc, dp, "getPriorityTreeRoot()(bytes32)"),
                "event_signature": sig_prio,
                "pending": prio,
            },
            "message_root": {
                "interop_enabled": call(rpc, mr, "isInteropEnabled(uint256)(bool)", cid_s),
                "current_chain_batch_number": int(call(rpc, mr, "currentChainBatchNumber(uint256)(uint256)", cid_s)),
                "chain_tree_leaf_count": int(call(rpc, mr, "chainTreeLeafCount(uint256)(uint256)", cid_s)),
                "chain_batch_root_0": call(rpc, mr, "chainBatchRoots(uint256,uint256)(bytes32)", cid_s, "0"),
            },
            "interop_pool": {
                "backfill_pending": call(rpc, ntv, "chainBalanceBackfillPending(uint256)(bool)", cid_s),
                "moved": {name: call(rpc, ntv, "chainBalanceInInteropPool(uint256,bytes32)(bool)", cid_s, t["asset_id"])
                          for name, t in res["tokens"].items() if name != "zk"},
            },
            "interop_peers_allowed": {
                str(p): call(rpc, crs, "interopPeerAllowed(uint256,uint256)(bool)", cid_s, str(p))
                for p in chain_ids if p != cid
            },
        }

    with open(a.out, "w") as f:
        json.dump(res, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
