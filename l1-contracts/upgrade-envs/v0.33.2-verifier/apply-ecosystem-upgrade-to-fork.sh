#!/usr/bin/env bash
# Apply the v0.33.2 ecosystem upgrade to an anvil fork, the way it really executes: the CREATE2
# deployments from `[deploy_calls]`, then each governance stage as the Governance owner's
# `scheduleTransparent` + `execute` (`[governance_operations]`). Afterwards the CTM has the cut for
# v0.33.0 registered, which is what the per-chain bundles consume.
#
# The fork must run with --auto-impersonate. Fails on the first transaction that does not succeed.
# Usage: RPC=http://127.0.0.1:<port> ./apply-ecosystem-upgrade-to-fork.sh
set -euo pipefail

: "${RPC:?set RPC to an anvil fork started with --auto-impersonate}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${ECOSYSTEM_TOML:-$HERE/output/stage/ecosystem.toml}

toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }
send() {
  cast rpc anvil_setBalance "$1" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  cast send --unlocked --from "$1" "$2" "$3" --rpc-url "$RPC" >/dev/null || { echo "FAILED: $4"; exit 1; }
  echo "  ok   $4"
}

DEPLOYER=$(toml_get deploy_calls.deployer)
cast abi-decode --json --input 'f((address,uint256,bytes)[])' "$(toml_get deploy_calls.calls)" | python3 -c "
import json, sys
j = json.load(sys.stdin)
for target, value, data in (j['data'] if isinstance(j, dict) else j)[0]:
    print(target, data)" | while read -r target data; do
  send "$DEPLOYER" "$target" "$data" "CREATE2 deployment"
done

GOV=$(cast call "$(toml_get state_transition.chain_type_manager_proxy)" 'owner()(address)' --rpc-url "$RPC")
GOV_OWNER=$(toml_get governance_operations.governance_owner)
for STAGE in 0 1 2; do
  send "$GOV_OWNER" "$GOV" "$(toml_get governance_operations.stage${STAGE}_schedule_calldata)" "stage $STAGE scheduleTransparent"
  send "$GOV_OWNER" "$GOV" "$(toml_get governance_operations.stage${STAGE}_execute_calldata)" "stage $STAGE execute"
done
