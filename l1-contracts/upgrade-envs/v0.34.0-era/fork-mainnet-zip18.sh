#!/usr/bin/env bash
# Test-only: a mainnet Anvil fork with ZIP-18 (v31: Era CTM v0.30.1 -> v0.33.0) replayed, so the v34 mainnet path
# can be rehearsed before ZIP-18 executes. Retire it once ZIP-18 is live, and fork real mainnet instead.
#
# On a fresh fork it:
#   1. checks ZIP-18's contracts are deployed and its L2 upgrade's factory deps published;
#   2. replays ZIP-18's Safe bundles 02 (ServerNotifier upgrades) and 04 (the ZKsync OS timer's handover to
#      the PUH) as the Safe;
#   3. sends ZIP-18's governance stages 0/1/2 as the PUH, with 200,000 s between stages 0 and 1 (both
#      timers), then registers ETH in the L1AssetTracker: v31's permissionless legacy-token registration, which
#      follows ZIP-18 and which deposits need;
#   4. drains chain 324 through the ValidatorTimelock and upgrades it to v0.33.0 with ZIP-18's chain call,
#      sent by the Safe through the ChainAdmin;
#   5. checks the CTM and chain 324 are where v34's mainnet.toml expects them.
# ZIP-18's test transactions are not replayed: they create chain 555, v34's test chain.
#
# The Anvil is left running, so that `protocol_ops ecosystem rehearse-upgrade --env mainnet --fork-url
# http://127.0.0.1:$PORT` and `replay-bundle` can fork it. Send nothing else to it until they have finished, and
# stop it with the kill command printed at the end. Their forks use 29_549 and 29_550, so PORT must differ.
#
# Needs: foundry (anvil, cast), python3 >= 3.11 (tomllib), git (reads ZIP-18's output at tag zip-18).
# Usage: L1_FORK_URL=<mainnet rpc> [FORK_BLOCK=<n>] [PORT=8645] ./fork-mainnet-zip18.sh
# The RPC must keep the fork block's state for the whole session (hours); public RPCs prune it.
set -uo pipefail

: "${L1_FORK_URL:?set L1_FORK_URL to a mainnet RPC}"
PORT=${PORT:-8645}
case "$PORT" in 29549 | 29550) echo "FAILED: ports 29549/29550 are protocol_ops' mainnet forks; set PORT"; exit 1 ;; esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S=$(mktemp -d)
RPC=http://127.0.0.1:$PORT
ZIP18_OUT=l1-contracts/upgrade-envs/v0.31.0-interopB/output/mainnet
FAILED=0
python3 -c 'import tomllib' 2>/dev/null || { echo "FAILED: needs python3 >= 3.11 (tomllib)"; exit 1; }

fail() { echo "  FAIL $*"; FAILED=$((FAILED + 1)); }
# chk LABEL GOT EXPECTED — an empty EXPECTED is a failed read, never a match.
chk() {
  [ -n "$3" ] || { fail "$1: no expected value (failed read), got ${2:-nothing}"; return; }
  [ "$(echo "$2" | tr A-F a-f)" = "$(echo "$3" | tr A-F a-f)" ] && echo "  OK   $1" || fail "$1: expected $3, got $2"
}
call() { cast call "$@" --rpc-url "$RPC"; }
first() { awk '{print $1}'; }
# send FROM TO DATA LABEL — impersonated; stops the run on a failed transaction, since later steps build on it.
send() {
  cast send --unlocked --from "$1" "$2" "$3" --rpc-url "$RPC" --json 2> "$S/send.err" | grep '^{' | tail -1 > "$S/receipt.json"
  st=$(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(r.get("data", r).get("status"))' "$S/receipt.json" 2>/dev/null)
  [ "$st" = "0x1" ] && echo "  OK   $4" || { fail "$4 (status ${st:-none}: $(head -c 300 "$S/send.err"))"; finish; }
}
finish() {
  echo
  if [ "$FAILED" = "0" ]; then
    echo "ZIP-18 REPLAYED on $RPC (anvil PID $ANVIL_PID). Stop it with: kill $ANVIL_PID"
  else
    kill "$ANVIL_PID" 2>/dev/null
    echo "ZIP-18 REPLAY FAILED ($FAILED); anvil stopped"
    exit 1
  fi
  exit 0
}

# ZIP-18's committed output, from its tag.
git -C "$HERE" show "zip-18:$ZIP18_OUT/ecosystem.toml" > "$S/zip18.toml" || { echo "FAILED: no tag zip-18"; exit 1; }
for b in 02 04; do
  git -C "$HERE" show "zip-18:$ZIP18_OUT/sim-inputs/${b}_ecosystem.upgrade-prepare-all_0x4e4943346848c4867f81dfb37c4ca9c5715a7828.safe.json" \
    > "$S/bundle_$b.json" || { echo "FAILED: no Safe bundle $b at zip-18"; exit 1; }
done

# Never send to another session's anvil.
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && { echo "FAILED: port $PORT is in use; set PORT"; exit 1; }
nohup anvil --fork-url "$L1_FORK_URL" ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} --port "$PORT" \
  --auto-impersonate --disable-block-gas-limit --silent > "$S/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  kill -0 "$ANVIL_PID" 2>/dev/null || break
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
kill -0 "$ANVIL_PID" 2>/dev/null || { echo "FAILED: anvil exited (log: $S/anvil.log)"; exit 1; }
[ "$(cast chain-id --rpc-url "$RPC")" = "1" ] || { fail "not a mainnet fork"; finish; }
echo "mainnet fork at block $(cast block-number --rpc-url "$RPC") on $RPC (anvil PID $ANVIL_PID)"

# Everything the replay needs from ZIP-18's output: addresses to check, calls to send, expected hashes.
python3 - "$S" <<'PYZIP18' || { fail "cannot read ZIP-18's output"; finish; }
import json, subprocess, sys, tomllib
S = sys.argv[1]
z = tomllib.load(open(f"{S}/zip18.toml", "rb"))
ZERO = "0x" + "00" * 20

def decode(types, data):
    out = subprocess.run(["cast", "abi-decode", "--json", "--input", f"f({types})", data], capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    return (d["data"] if isinstance(d, dict) and "data" in d else d)

CALLS = "(address,uint256,bytes)[]"
# Contracts ZIP-18 deployed or relies on: every address in its core, CTM and governance tables.
contracts = set()
def walk(prefix, t):
    for k, v in t.items():
        if isinstance(v, dict):
            walk(f"{prefix}.{k}", v)
        elif isinstance(v, str) and len(v) == 42 and v.startswith("0x") and v.lower() != ZERO:
            contracts.add((f"{prefix}.{k}", v))
for section in ["core", "zk_governance"]:
    walk(section, z[section])
for ctm in ["era", "zksync_os"]:
    for part in ["state_transition", "deployed_addresses"]:
        walk(f"ctms.{ctm}.{part}", z["ctms"][ctm][part])
open(f"{S}/contracts.txt", "w").write("".join(f"{k} {v}\n" for k, v in sorted(contracts)))

# The Era chain upgrade's L2 transaction: its factory deps must be in ZIP-18's BytecodesSupplier.
CUT = "((address,uint8,bool,bytes4[])[],address,bytes)"
L2TX = "(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes)"
PU = f"({L2TX},bytes32,bytes32,bytes32,address,(bytes32,bytes32,bytes32),bytes,bytes,uint256,uint256)"
cut = decode(CUT, z["ctms"]["era"]["chain_upgrade_diamond_cut"])[0]
pu = decode(PU, "0x" + cut[2][10:])[0]
open(f"{S}/factory_deps.txt", "w").write("".join("0x%064x\n" % int(str(h), 0) for h in pu[0][13]))

for n in range(3):
    calls = decode(CALLS, z["governance_calls"][f"stage{n}_calls"])[0]
    open(f"{S}/stage{n}.txt", "w").write("".join(f"{c[0]} {int(str(c[1]), 0)} {c[2]}\n" for c in calls))
for b in ["02", "04"]:
    txs = json.load(open(f"{S}/bundle_{b}.json"))["transactions"]
    open(f"{S}/bundle_{b}.txt", "w").write("".join(f"{t['to']} {int(str(t.get('value') or 0), 0)} {t['data']}\n" for t in txs))
test = z["test_upgrade_calls"]
upgrade = decode(CALLS, test["test_upgrade_chain_era"])[0]
assert len(upgrade) == 1, "test_upgrade_chain_era: expected one call"
st = z["ctms"]["era"]["state_transition"]
with open(f"{S}/zip18.env", "w") as f:
    for k, v in {
        "SUPPLIER": st["bytecodes_supplier_addr"], "CTM": st["chain_type_manager_proxy"], "VERIFIER": st["verifier_addr"],
        "VT": st["validator_timelock_addr"], "CHAIN_ADMIN": test["test_upgrade_chain_era_caller"],
        "SAFE": z["ctms"]["era"]["ctm_admin_calls"]["chain_admin_owner"],
        "UPGRADE_TARGET": upgrade[0][0], "UPGRADE_DATA": upgrade[0][2],
        "OLD": z["ctms"]["era"]["contracts_config"]["old_protocol_version"],
        "NEW": z["ctms"]["era"]["contracts_config"]["new_protocol_version"],
        "BOARD": z["zk_governance"]["new_emergency_upgrade_board"],
        "ASSET_TRACKER": z["core"]["upgrade_addresses"]["bridgehub"]["l1_asset_tracker_proxy_addr"],
    }.items():
        f.write(f"{k}={v}\n")
PYZIP18
# shellcheck disable=SC1091
. "$S/zip18.env"
PUH=$(call "$CTM" 'owner()(address)')
DIAMOND=$(call "$CTM" 'getZKChain(uint256)(address)' 324)
echo "PUH $PUH | Safe $SAFE | chain 324 $DIAMOND | ChainAdmin $CHAIN_ADMIN"
chk "ZIP-18's chain call targets chain 324's diamond" "$UPGRADE_TARGET" "$DIAMOND"
chk "CTM on v0.30.1 (ZIP-18 not executed on this fork)" "$(call "$CTM" 'protocolVersion()(uint256)' | first)" "$OLD"
for a in "$PUH" "$SAFE" "$CHAIN_ADMIN"; do cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null; done

echo "== 1. ZIP-18's contracts and factory deps"
NOCODE=0
while read -r key addr; do
  [ "$(cast code "$addr" --rpc-url "$RPC")" = "0x" ] && { NOCODE=$((NOCODE + 1)); echo "     no code: $key $addr"; }
done < "$S/contracts.txt"
chk "every contract ZIP-18's output names has code ($(wc -l < "$S/contracts.txt" | tr -d ' '))" "$NOCODE" 0
UNPUB=0
while read -r h; do
  b=$(call "$SUPPLIER" 'publishingBlock(bytes32)(uint256)' "$h" | first)
  case "$b" in '' | *[!0-9]* | 0) UNPUB=$((UNPUB + 1)); echo "     unpublished: $h" ;; esac
done < "$S/factory_deps.txt"
chk "every factory dep of ZIP-18's L2 upgrade is published ($(wc -l < "$S/factory_deps.txt" | tr -d ' '))" "$UNPUB" 0
[ "$FAILED" = "0" ] || finish

echo "== 2. Safe bundles 02 and 04, as the Safe"
for b in 02 04; do
  while read -r to value data; do send "$SAFE" "$to" "$data" "bundle $b: ${data:0:10} -> $to"; done < "$S/bundle_$b.txt"
done

echo "== 3. ZIP-18's governance stages, as the PUH"
while read -r to value data; do send "$PUH" "$to" "$data" "stage 0 ${data:0:10} -> $to"; done < "$S/stage0.txt"
# Past both timers (Era 172,800 s; the ZKsync OS one too).
cast rpc evm_increaseTime 200000 --rpc-url "$RPC" >/dev/null && cast rpc evm_mine --rpc-url "$RPC" >/dev/null
echo "     advanced the fork's time by 200,000 s"
for n in 1 2; do
  while read -r to value data; do send "$PUH" "$to" "$data" "stage $n ${data:0:10} -> $to"; done < "$S/stage$n.txt"
done

BRIDGEHUB=$(call "$CTM" 'BRIDGE_HUB()(address)')
ETH_ASSET=$(call "$BRIDGEHUB" 'baseTokenAssetId(uint256)(bytes32)' 324)
if [ "$(call "$ASSET_TRACKER" 'isAssetRegistered(bytes32)(bool)' "$ETH_ASSET")" = "false" ]; then
  send "$SAFE" "$ASSET_TRACKER" "$(cast calldata 'registerLegacyToken(bytes32)' "$ETH_ASSET")" \
    "registerLegacyToken(ETH $ETH_ASSET) (permissionless; sent by the Safe)"
fi
chk "ETH registered in the L1AssetTracker" "$(call "$ASSET_TRACKER" 'isAssetRegistered(bytes32)(bool)' "$ETH_ASSET")" true

echo "== 4. Chain 324: drain, then ZIP-18's upgrade, sent by the Safe through the ChainAdmin"
counts() { echo "$(call "$DIAMOND" 'getTotalBatchesCommitted()(uint256)' | first) $(call "$DIAMOND" 'getTotalBatchesExecuted()(uint256)' | first)"; }
read -r COMMITTED EXECUTED <<< "$(counts)"
echo "     committed / executed: $COMMITTED / $EXECUTED"
if [ "$COMMITTED" != "$EXECUTED" ]; then
  ROLE=$(cast keccak REVERTER_ROLE)
  REVERTER=$(call "$VT" 'getRoleMember(address,bytes32,uint256)(address)' "$DIAMOND" "$ROLE" 0)
  cast rpc anvil_setBalance "$REVERTER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  send "$REVERTER" "$VT" "$(cast calldata 'revertBatchesSharedBridge(address,uint256)' "$DIAMOND" "$EXECUTED")" \
    "revertBatchesSharedBridge(324, $EXECUTED) by the REVERTER_ROLE holder $REVERTER"
fi
send "$SAFE" "$CHAIN_ADMIN" "$(cast calldata 'multicall((address,uint256,bytes)[],bool)' "[($DIAMOND,0,$UPGRADE_DATA)]" true)" \
  "ChainAdmin multicall(ZIP-18's upgradeChainFromVersion for 324)"

echo "== 5. Where v34's mainnet.toml expects the fork"
chk "CTM protocolVersion = v0.33.0" "$(call "$CTM" 'protocolVersion()(uint256)' | first)" "$NEW"
chk "CTM protocolVersionVerifier(v0.33.0) = ZIP-18's verifier" "$(call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$NEW")" "$VERIFIER"
chk "CTM initialCutHash = keccak(ZIP-18's diamond_cut_data)" "$(call "$CTM" 'initialCutHash()(bytes32)')" \
  0x51d870a86c347912cd3999bbceb76f491e1984d0728c9faae7000009e7f20512
chk "CTM initialForceDeploymentHash = keccak(abi.encode(ZIP-18's force_deployments_data))" \
  "$(call "$CTM" 'initialForceDeploymentHash()(bytes32)')" 0x5a7a068cf085071451bc01005aebf994e7931ee14abf216b732e6d49c6225e54
chk "CTM L1_BYTECODES_SUPPLIER = ZIP-18's" "$(call "$CTM" 'L1_BYTECODES_SUPPLIER()(address)')" "$SUPPLIER"
chk "migrations unpaused" "$(call "$(call "$BRIDGEHUB" 'chainAssetHandler()(address)')" 'migrationPaused()(bool)')" false
chk "PUH emergencyUpgradeBoard = ZIP-18's new board" "$(call "$PUH" 'emergencyUpgradeBoard()(address)')" "$BOARD"
chk "chain 324 protocol version = v0.33.0" "$(call "$DIAMOND" 'getProtocolVersion()(uint256)' | first)" "$NEW"
chk "chain 324 verifier = ZIP-18's" "$(call "$DIAMOND" 'getVerifier()(address)')" "$VERIFIER"
PENDING=$(call "$DIAMOND" 'getL2SystemContractsUpgradeTxHash()(bytes32)')
[ "$PENDING" != "0x0000000000000000000000000000000000000000000000000000000000000000" ] \
  && echo "  OK   chain 324 has ZIP-18's L2 upgrade pending ($PENDING): its v34 upgrade must revert" \
  || fail "chain 324 has no pending L2 upgrade"
read -r COMMITTED EXECUTED <<< "$(counts)"
chk "chain 324 drained (committed = executed)" "$COMMITTED" "$EXECUTED"
finish
