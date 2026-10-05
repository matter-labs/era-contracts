#!/usr/bin/env bash
# Rehearse the v0.33.2 verifier-only stage upgrade on a Sepolia fork, along the path it really takes,
# and assert the resulting L1 state:
#   1. the CREATE2 deployments from `[deploy_calls]`, sent by `[deploy_calls].deployer`
#   2. governance stages 0/1/2 as the Governance owner's `scheduleTransparent` + `execute`
#      (`[governance_operations]`), impersonated
#   3. per chain: `ServerNotifier.setUpgradeTimestamp`, then `[chain_upgrades.<id>].chain_admin_calldata`,
#      both through the chain's ChainAdmin. A chain with committed-but-unexecuted batches at the fork
#      block must refuse the cut (`NotAllBatchesExecuted`); every other chain must upgrade
#   4. `[test_upgrade_calls].test_create_chain_zkos` as the bridgehub admin
#   5. assertions: versions, verifiers, VK, stored cut hash, facets and creation params unchanged,
#      migrations unpaused again
#
# Needs: foundry (forge/cast/anvil), python3, and an up-to-date output/stage/ecosystem.toml.
# Usage: L1_FORK_URL=<sepolia rpc> ./rehearse-stage.sh      (PORT defaults to 8733)
# Only the anvil it starts is stopped (by PID).
set -uo pipefail

: "${L1_FORK_URL:?set L1_FORK_URL to a Sepolia RPC}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=$HERE/output/stage/ecosystem.toml
S=$(mktemp -d)
PORT=${PORT:-8733}
RPC=http://127.0.0.1:$PORT
FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }
chk() { [ "$(echo "$2" | tr A-F a-f)" = "$(echo "$3" | tr A-F a-f)" ] && echo "  OK   $1" || fail "$1: expected $3, got $2"; }
toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }
# send <from> <to> <calldata> -> receipt status
send() {
  cast rpc anvil_setBalance "$1" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  cast send --unlocked --from "$1" "$2" "$3" --rpc-url "$RPC" --json 2>&1 | python3 -c "
import json, sys
L = [l for l in sys.stdin.read().splitlines() if l.startswith('{')]
r = json.loads(L[-1]) if L else {}
r = r.get('data', r) if isinstance(r.get('data'), dict) else r
print(r.get('status', 'reverted'))"
}
call() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
# `cast ... --json` output, unwrapped from the {"data": ...} envelope newer foundry versions add.
cast_json() { cast "$@" --json | python3 -c "import json,sys; j=json.load(sys.stdin); print(json.dumps(j['data'] if isinstance(j, dict) else j))"; }

anvil --fork-url "$L1_FORK_URL" --port "$PORT" --auto-impersonate --silent > "$S/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
echo "fork block: $(cast block-number --rpc-url "$RPC")"

CTM=$(toml_get state_transition.chain_type_manager_proxy)
BH=$(call "$CTM" 'BRIDGE_HUB()(address)')
CAH=$(call "$BH" 'chainAssetHandler()(address)')
GOV=$(call "$CTM" 'owner()(address)')
OLD=$(toml_get contracts_config.old_protocol_version)
NEW=$(toml_get contracts_config.new_protocol_version)
VERIFIER=$(toml_get state_transition.verifier_addr)
VK=$(toml_get verification_key.new_vk_hash)
INITIAL_CUT_HASH=$(call "$CTM" 'initialCutHash()(bytes32)')
FORCE_DEPLOYMENT_HASH=$(call "$CTM" 'initialForceDeploymentHash()(bytes32)')

# ---------------------------------------------------------------- 1. deployments
DEPLOYER=$(toml_get deploy_calls.deployer)
cast_json abi-decode --input 'f((address,uint256,bytes)[])' "$(toml_get deploy_calls.calls)" | python3 -c "
import json, sys
for target, value, data in json.load(sys.stdin)[0]:
    print(target, data)" > "$S/deploy_calls.txt"
while read -r target data; do
  st=$(send "$DEPLOYER" "$target" "$data"); echo "deploy via $target: status $st"
  [ "$st" = "0x1" ] || fail "deployment failed"
done < "$S/deploy_calls.txt"
chk "verifier VK" "$(call "$VERIFIER" 'verificationKeyHash()(bytes32)')" "$VK"
chk "verifier wraps verifier_plonk" "$(call "$VERIFIER" 'PLONK_VERIFIER()(address)')" "$(toml_get state_transition.verifier_plonk_addr)"
chk "verifier is the testnet flavour" "$(call "$VERIFIER" 'IS_TESTNET_VERIFIER()(bool)')" "true"

chk "CTM stored default upgrade unchanged" "$(call "$CTM" 'defaultUpgrade()(address)')" "$(toml_get state_transition.ctm_stored_default_upgrade_addr)"

# ---------------------------------------------------------------- 2. governance
GOV_OWNER=$(toml_get governance_operations.governance_owner)
chk "Governance owner" "$(call "$GOV" 'owner()(address)')" "$GOV_OWNER"
for STAGE in 0 1 2; do
  st=$(send "$GOV_OWNER" "$GOV" "$(toml_get governance_operations.stage${STAGE}_schedule_calldata)")
  echo "stage $STAGE scheduleTransparent: status $st"; [ "$st" = "0x1" ] || fail "stage $STAGE schedule failed"
  st=$(send "$GOV_OWNER" "$GOV" "$(toml_get governance_operations.stage${STAGE}_execute_calldata)")
  echo "stage $STAGE execute: status $st"; [ "$st" = "0x1" ] || fail "stage $STAGE execute failed"
  chk "stage $STAGE operation done" "$(call "$GOV" 'isOperationDone(bytes32)(bool)' "$(toml_get governance_operations.stage${STAGE}_operation_id)")" "true"
done
# The operations must carry exactly the [governance_calls] the simulator scenario carries.
python3 - "$OUT" <<'PYCHECK' && echo "  OK   governance operations = [governance_calls]" || fail "governance operations differ from [governance_calls]"
import json, subprocess, sys, tomllib
def cast_json(*args):
    j = json.loads(subprocess.check_output(["cast", *args, "--json"]))
    return j["data"] if isinstance(j, dict) else j
d = tomllib.load(open(sys.argv[1], "rb"))
norm = lambda cs: [(t.lower(), int(str(v), 0), x.lower()) for t, v, x in cs]
for stage in range(3):
    calls = cast_json("abi-decode", "--input", "f((address,uint256,bytes)[])", d["governance_calls"][f"stage{stage}_calls"])
    op = cast_json("calldata-decode", "execute(((address,uint256,bytes)[],bytes32,bytes32))",
                   d["governance_operations"][f"stage{stage}_execute_calldata"])
    if norm(calls[0]) != norm(op[0][0]):
        sys.exit(1)
PYCHECK

chk "upgrade timer started" "$([ "$(call "$(toml_get deployed_addresses.l1_governance_upgrade_timer)" 'deadline()(uint256)')" != "0" ] && echo yes)" "yes"
chk "CTM protocolVersion" "$(call "$CTM" 'protocolVersion()(uint256)')" "$NEW"
chk "CTM verifier for the new version" "$(call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$NEW")" "$VERIFIER"
chk "CTM stored cut = upgrade_cut_data" "$(call "$CTM" 'upgradeCutHash(uint256)(bytes32)' "$OLD")" "$(cast keccak "$(toml_get chain_upgrade_diamond_cut)")"
chk "old version still active" "$(call "$CTM" 'protocolVersionIsActive(uint256)(bool)' "$OLD")" "true"
chk "creation cut unchanged" "$(call "$CTM" 'initialCutHash()(bytes32)')" "$INITIAL_CUT_HASH"
chk "force deployments unchanged" "$(call "$CTM" 'initialForceDeploymentHash()(bytes32)')" "$FORCE_DEPLOYMENT_HASH"
chk "creation params carried to the new version" "$(call "$CTM" 'newChainCreationParamsBlock(uint256)(uint256)' "$NEW")" "$(call "$CTM" 'newChainCreationParamsBlock(uint256)(uint256)' "$OLD")"
chk "migrations unpaused again" "$(call "$CAH" 'migrationPaused()(bool)')" "false"

# ---------------------------------------------------------------- 3. chains
SERVER_NOTIFIER=$(call "$CTM" 'serverNotifierAddress()(address)')
NOW=$(cast block --rpc-url "$RPC" -f timestamp)
UPGRADED=0
for CHAIN_ID in $(python3 -c "import tomllib; print(' '.join(tomllib.load(open('$OUT','rb'))['chain_upgrades']))"); do
  CHAIN=$(toml_get chain_upgrades.$CHAIN_ID.chain)
  ADMIN=$(toml_get chain_upgrades.$CHAIN_ID.chain_admin)
  OWNER=$(toml_get chain_upgrades.$CHAIN_ID.chain_admin_owner)
  FACETS_BEFORE=$(cast call "$CHAIN" 'facetAddresses()(address[])' --rpc-url "$RPC")
  COMMITTED=$(call "$CHAIN" 'getTotalBatchesCommitted()(uint256)')
  EXECUTED=$(call "$CHAIN" 'getTotalBatchesExecuted()(uint256)')
  TS_CALLDATA=$(cast calldata 'multicall((address,uint256,bytes)[],bool)' \
    "[($SERVER_NOTIFIER,0,$(cast calldata 'setUpgradeTimestamp(uint256,uint256)' "$CHAIN_ID" "$NOW"))]" true)
  st=$(send "$OWNER" "$ADMIN" "$TS_CALLDATA"); [ "$st" = "0x1" ] || fail "chain $CHAIN_ID setUpgradeTimestamp failed"
  st=$(send "$OWNER" "$ADMIN" "$(toml_get chain_upgrades.$CHAIN_ID.chain_admin_calldata)")
  if [ "$COMMITTED" = "$EXECUTED" ]; then
    echo "chain $CHAIN_ID (batches $EXECUTED/$COMMITTED executed): upgrade status $st"
    [ "$st" = "0x1" ] || fail "chain $CHAIN_ID upgrade failed"
    chk "chain $CHAIN_ID protocolVersion" "$(call "$CHAIN" 'getProtocolVersion()(uint256)')" "$NEW"
    chk "chain $CHAIN_ID verifier" "$(call "$CHAIN" 'getVerifier()(address)')" "$VERIFIER"
    chk "chain $CHAIN_ID facets unchanged" "$(cast call "$CHAIN" 'facetAddresses()(address[])' --rpc-url "$RPC")" "$FACETS_BEFORE"
    UPGRADED=$((UPGRADED + 1))
  else
    echo "chain $CHAIN_ID (batches $EXECUTED/$COMMITTED executed): upgrade status $st, must wait for its batches"
    REVERT=$(cast call --from "$OWNER" "$ADMIN" "$(toml_get chain_upgrades.$CHAIN_ID.chain_admin_calldata)" --rpc-url "$RPC" 2>&1)
    # NotAllBatchesExecuted() = 0xf9ba09d6
    [ "$st" != "0x1" ] && echo "$REVERT" | grep -q 0xf9ba09d6 \
      && echo "  OK   chain $CHAIN_ID refuses the cut with NotAllBatchesExecuted" \
      || fail "chain $CHAIN_ID: expected NotAllBatchesExecuted, got status $st / $REVERT"
    chk "chain $CHAIN_ID still on the old version" "$(call "$CHAIN" 'getProtocolVersion()(uint256)')" "$OLD"
  fi
done
[ "$UPGRADED" -gt 0 ] || fail "no chain was idle at the fork block, the per-chain upgrade was not exercised"

# ---------------------------------------------------------------- 4. test chain creation
TC_CALLER=$(toml_get test_upgrade_calls.test_create_chain_zkos_caller)
read -r TC_TARGET TC_DATA < <(cast_json abi-decode --input 'f((address,uint256,bytes)[])' \
  "$(toml_get test_upgrade_calls.test_create_chain_zkos)" | python3 -c "
import json, sys
calls = json.load(sys.stdin)[0]
assert len(calls) == 1, calls
print(calls[0][0], calls[0][2])")
TC_ID=$((16#${TC_DATA:10:64}))
st=$(send "$TC_CALLER" "$TC_TARGET" "$TC_DATA"); echo "test createNewChain($TC_ID): status $st"
[ "$st" = "0x1" ] || fail "test chain creation failed"
NEW_CHAIN=$(call "$BH" 'getZKChain(uint256)(address)' "$TC_ID")
chk "new chain protocolVersion" "$(call "$NEW_CHAIN" 'getProtocolVersion()(uint256)')" "$NEW"
chk "new chain verifier" "$(call "$NEW_CHAIN" 'getVerifier()(address)')" "$VERIFIER"

echo
if [ "$FAILED" = "0" ]; then
  echo "REHEARSAL PASSED"
else
  echo "REHEARSAL FAILED"
  exit 1
fi
