#!/usr/bin/env bash
# Rehearse the v33 compiler-only stage upgrade on a Sepolia fork and assert the resulting L1 state:
#   1. CTMUpgrade_v33.prepare  — publishes the factory deps (fork only), writes output/stage/ecosystem.toml
#   2. governance stages 0/1/2 — sent as the CTM owner (stage's ProtocolUpgradeHandler), impersonated
#   3. chain 499's ChainAdmin multicall — sent as the ChainAdmin's owner, impersonated
#   4. assertions: versions, base-system hashes, verifier and facets unchanged, L2 upgrade tx scheduled,
#      chain-creation cut replaced, migrations unpaused again
#
# Needs: foundry (forge/cast/anvil), python3, and the Linux CI build artifacts in
# {system,l1,l2}-contracts/zkout (a macOS zksolc build produces different hashes).
# Usage: L1_FORK_URL=<sepolia archive rpc> ./rehearse-stage.sh      (PORT defaults to 8633)
# Only the anvil it starts is stopped (by PID).
set -uo pipefail

: "${L1_FORK_URL:?set L1_FORK_URL to a Sepolia RPC}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(cd "$HERE/../.." && pwd)
S=$(mktemp -d)
PORT=${PORT:-8633}
RPC=http://127.0.0.1:$PORT
FORK="$L1_FORK_URL"
OUT_REL=/upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml
OUT=$WT$OUT_REL
DEPLOYER=${DEPLOYER:-0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7}
CTM=0x8b448ac7cd0f18F3d8464E2645575772a26A3b6b
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

anvil --fork-url "$FORK" --port "$PORT" --auto-impersonate --silent > "$S/anvil_v33.log" 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
echo "fork block: $(cast block-number --rpc-url "$RPC")"
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null

# ---------------------------------------------------------------- 1. prepare
mkdir -p "$(dirname "$OUT")"
# Never assert against an output left over from an earlier run.
rm -f "$OUT"
cd "$WT"
forge script deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol:CTMUpgrade_v33 \
  --sig 'prepare(string,string)' /upgrade-envs/v0.33.0-compiler/stage.toml "$OUT_REL" \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --legacy --slow \
  > "$S/v33_prepare.log" 2>&1
PREPARE_EXIT=$?
echo "prepare exit: $PREPARE_EXIT"; grep -E 'v33:|Error|revert|ONCHAIN EXECUTION' "$S/v33_prepare.log" | tail -8
if [ "$PREPARE_EXIT" != "0" ] || [ ! -f "$OUT" ]; then
  echo "REHEARSAL FAILED: prepare did not produce an output (log: $S/v33_prepare.log)"
  exit 1
fi

toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }
NEW_BOOT=$(toml_get contracts_config.bootloader_hash)
NEW_AA=$(toml_get contracts_config.default_aa_hash)
NEW_EVM=$(toml_get contracts_config.evm_emulator_hash)
NEW_VER=$(toml_get contracts_config.new_protocol_version)
VERIFIER=$(toml_get contracts_config.verifier)
echo "new hashes: boot $NEW_BOOT aa $NEW_AA evm $NEW_EVM; version $NEW_VER"

# every factory dep of the L2 upgrade tx must be published in the supplier
python3 -c "import tomllib; [print(h) for h in tomllib.load(open('$OUT','rb'))['contracts_config']['l2_upgrade_tx_factory_deps']]" > "$S/v33_factory_deps.txt"
BS=$(toml_get contracts_config.bytecodes_supplier)
UNPUB=0; N=0
while read -r h; do N=$((N+1)); b=$(cast call "$BS" 'publishingBlock(bytes32)(uint256)' "$h" --rpc-url "$RPC" | awk '{print $1}'); [ "$b" = "0" ] && UNPUB=$((UNPUB+1)); done < "$S/v33_factory_deps.txt"
echo "L2 upgrade tx factory deps: $N, unpublished after prepare: $UNPUB"
[ "$UNPUB" = "0" ] || fail "factory deps not published"

# ---------------------------------------------------------------- 2. governance stage 1
OWNER=$(cast call "$CTM" 'owner()(address)' --rpc-url "$RPC")
cast rpc anvil_setBalance "$OWNER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
CHAIN=$(toml_get chain_upgrades.499.chain)
FACETS_BEFORE=$(cast call "$CHAIN" 'facetAddresses()(address[])' --rpc-url "$RPC")
for STAGE in 0 1 2; do
  CALLS=$(toml_get governance_calls.stage${STAGE}_calls)
  cast abi-decode --json --input 'f((address,uint256,bytes)[])' "$CALLS" | python3 -c "
import json, sys
for target, value, data in json.load(sys.stdin)[0]:
    print(target, int(str(value), 0), data)" > "$S/v33_stage${STAGE}_calls.txt"
  echo "stage-$STAGE calls: $(wc -l < "$S/v33_stage${STAGE}_calls.txt" | tr -d ' ')"
  while read -r target value data; do
    st=$(cast send --unlocked --from "$OWNER" "$target" "$data" --value "$value" --rpc-url "$RPC" --json 2>&1 | python3 -c "import json,sys; L=[l for l in sys.stdin.read().splitlines() if l.startswith('{')]; print(json.loads(L[-1])['status'] if L else 'no-receipt')")
    echo "  ${data:0:10} -> $target: status $st"
    [ "$st" = "0x1" ] || fail "stage-$STAGE call ${data:0:10} failed"
  done < "$S/v33_stage${STAGE}_calls.txt"
done
[ "$(cast call "$(cast call "$(cast call "$CTM" 'BRIDGE_HUB()(address)' --rpc-url "$RPC")" 'chainAssetHandler()(address)' --rpc-url "$RPC")" 'migrationPaused()(bool)' --rpc-url "$RPC")" = "false" ] && echo "  OK   migrations unpaused again" || fail "migrations still paused"

# ---------------------------------------------------------------- 3. chain upgrade
ADMIN=$(toml_get chain_upgrades.499.chain_admin)
ADMIN_CALLDATA=$(toml_get chain_upgrades.499.chain_admin_calldata)
ADMIN_OWNER=$(cast call "$ADMIN" 'owner()(address)' --rpc-url "$RPC" 2>/dev/null || true)
if [ -n "$ADMIN_OWNER" ]; then
  cast rpc anvil_setBalance "$ADMIN_OWNER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  st=$(cast send --unlocked --from "$ADMIN_OWNER" "$ADMIN" "$ADMIN_CALLDATA" --rpc-url "$RPC" --json 2>&1 | python3 -c "import json,sys; L=[l for l in sys.stdin.read().splitlines() if l.startswith('{')]; print(json.loads(L[-1])['status'] if L else 'no-receipt')")
  echo "chain 499 upgrade via ChainAdmin $ADMIN (owner $ADMIN_OWNER): status $st"
  [ "$st" = "0x1" ] || fail "chain upgrade failed"
else
  fail "ChainAdmin $ADMIN has no owner()"
fi

# ---------------------------------------------------------------- 3b. test chain creation
# The bridgehub admin creates a fresh Era chain with the v33 creation params: proves on L1 that the
# CTM accepts the re-issued cut and force-deployment data (hash checks in ChainTypeManagerBase).
TC_ID=$(toml_get test_calls.create_chain_id)
TC_CALLER=$(toml_get test_calls.create_chain_caller)
TC_TARGET=$(toml_get test_calls.create_chain_target)
TC_DATA=$(toml_get test_calls.create_chain_calldata)
cast rpc anvil_setBalance "$TC_CALLER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
st=$(cast send --unlocked --from "$TC_CALLER" "$TC_TARGET" "$TC_DATA" --rpc-url "$RPC" --json 2>&1 | python3 -c "import json,sys; L=[l for l in sys.stdin.read().splitlines() if l.startswith('{')]; print(json.loads(L[-1])['status'] if L else 'no-receipt')")
echo "test createNewChain($TC_ID) as bridgehub admin: status $st"
[ "$st" = "0x1" ] || fail "test chain creation failed"
NEW_CHAIN=$(cast call "$TC_TARGET" 'getZKChain(uint256)(address)' "$TC_ID" --rpc-url "$RPC")

# ---------------------------------------------------------------- 4. assertions
chk() { [ "$(echo "$2" | tr A-F a-f)" = "$(echo "$3" | tr A-F a-f)" ] && echo "  OK   $1" || fail "$1: expected $3, got $2"; }
echo "== L1 state after the upgrade =="
chk "CTM protocolVersion" "$(cast call "$CTM" 'protocolVersion()(uint256)' --rpc-url "$RPC" | awk '{print $1}')" "$NEW_VER"
chk "chain protocolVersion" "$(cast call "$CHAIN" 'getProtocolVersion()(uint256)' --rpc-url "$RPC" | awk '{print $1}')" "$NEW_VER"
chk "chain bootloader" "$(cast call "$CHAIN" 'getL2BootloaderBytecodeHash()(bytes32)' --rpc-url "$RPC")" "$NEW_BOOT"
chk "chain default AA" "$(cast call "$CHAIN" 'getL2DefaultAccountBytecodeHash()(bytes32)' --rpc-url "$RPC")" "$NEW_AA"
chk "chain EVM emulator" "$(cast call "$CHAIN" 'getL2EvmEmulatorBytecodeHash()(bytes32)' --rpc-url "$RPC")" "$NEW_EVM"
chk "chain verifier unchanged" "$(cast call "$CHAIN" 'getVerifier()(address)' --rpc-url "$RPC")" "$VERIFIER"
chk "CTM verifier for v33" "$(cast call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$NEW_VER" --rpc-url "$RPC")" "$VERIFIER"
chk "facets unchanged" "$(cast call "$CHAIN" 'facetAddresses()(address[])' --rpc-url "$RPC")" "$FACETS_BEFORE"
TXH=$(cast call "$CHAIN" 'getL2SystemContractsUpgradeTxHash()(bytes32)' --rpc-url "$RPC")
[ "$TXH" != "0x0000000000000000000000000000000000000000000000000000000000000000" ] && echo "  OK   L2 upgrade tx scheduled ($TXH)" || fail "no L2 upgrade tx scheduled"
# New-chain force-deployment data: must decode in this branch's FixedForceDeploymentsData layout,
# carry stage's values, and name this branch's compiled L2 built-ins (a v33 genesis knows no other).
python3 - "$(toml_get contracts_config.new_chain_creation_params)" "$WT/../AllContractsHashes.json" <<'PYCHECK' && echo "  OK   new-chain force-deployment data (current layout, stage values, branch bytecode)" || fail "new-chain force-deployment data"
import json, subprocess, sys
params = json.loads(subprocess.check_output(["cast", "abi-decode", "--json", "--input",
    "f((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))", sys.argv[1]]))[0]
blob = params[5]
layout = ("f((uint256,uint256,address,bytes32,address,uint256,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,"
          "bytes,bytes,address,address,address,address,bytes32))")
d = json.loads(subprocess.check_output(["cast", "abi-decode", "--json", "--input", layout, blob]))[0]
known = {(e.get("zkBytecodeHash") or "").lower() for e in json.load(open(sys.argv[2]))}
I = lambda x: int(str(x), 0)
ok = True
def check(name, cond):
    global ok
    if not cond:
        ok = False
        print("    mismatch:", name)
check("l1ChainId", I(d[0]) == 11155111)
check("eraChainId", I(d[1]) == 270)
check("l1AssetRouter", d[2].lower() == "0xfd3130ea0e8b7dd61ac3663328a66d97eb02f84b")
check("aliasedL1Governance", d[4].lower() == "0xa019627524aed610192132a425d6b9c32a173900")
check("maxNumberOfZKChains", I(d[5]) == 100)
check("aliasedChainRegistrationSender", d[18].lower() == "0xffb49e812de9264b53cbd21cea04ed69fbe08319")
check("zkTokenAssetId", d[20].lower() == "0xd7912bfd25000ee1b3355167866f960a61787b79cd2c7e791036fe6e85a73823")
check("l2TokenProxyBytecodeHash in branch hashes", d[3].lower() in known)
for i in range(6, 16):
    check(f"bytecode info #{i} in branch hashes", ("0x" + d[i][2:66]).lower() in known)
sys.exit(0 if ok else 1)
PYCHECK
EXPECTED_CUT_HASH=$(toml_get contracts_config.new_initial_cut_hash)
chk "CTM initialCutHash = v33 creation cut" "$(cast call "$CTM" 'initialCutHash()(bytes32)' --rpc-url "$RPC")" "$EXPECTED_CUT_HASH"

chk "new chain protocolVersion" "$(cast call "$NEW_CHAIN" 'getProtocolVersion()(uint256)' --rpc-url "$RPC" | awk '{print $1}')" "$NEW_VER"
chk "new chain bootloader" "$(cast call "$NEW_CHAIN" 'getL2BootloaderBytecodeHash()(bytes32)' --rpc-url "$RPC")" "$NEW_BOOT"
chk "new chain default AA" "$(cast call "$NEW_CHAIN" 'getL2DefaultAccountBytecodeHash()(bytes32)' --rpc-url "$RPC")" "$NEW_AA"
chk "new chain EVM emulator" "$(cast call "$NEW_CHAIN" 'getL2EvmEmulatorBytecodeHash()(bytes32)' --rpc-url "$RPC")" "$NEW_EVM"
echo
if [ "$FAILED" = "0" ]; then
  echo "REHEARSAL PASSED"
else
  echo "REHEARSAL FAILED"
  exit 1
fi
