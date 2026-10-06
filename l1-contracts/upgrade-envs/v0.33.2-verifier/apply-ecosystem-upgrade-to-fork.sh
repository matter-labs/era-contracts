#!/usr/bin/env bash
# Apply the v0.33.2 ecosystem upgrade to an anvil fork, the way it really executes: the CREATE2
# deployments from `[deploy_calls]` that the forked network does not have yet, then each governance
# stage as the Governance owner's `scheduleTransparent` + `execute` (`[governance_operations]`). Afterwards the CTM has the cut for
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
python3 -c "
import json, subprocess, tomllib
d = tomllib.load(open('$OUT', 'rb'))
st, dep = d['state_transition'], d['deployed_addresses']
addresses = [st['verifier_plonk_addr'], st['verifier_addr'], dep['upgrade_stage_validator'], dep['l1_governance_upgrade_timer']]
j = json.loads(subprocess.check_output(['cast', 'abi-decode', '--json', '--input', 'f((address,uint256,bytes)[])', d['deploy_calls']['calls']]))
calls = (j['data'] if isinstance(j, dict) else j)[0]
assert len(calls) == len(addresses) == len(d['deploy_calls']['contracts'])
for name, addr, (target, value, data) in zip(d['deploy_calls']['contracts'], addresses, calls):
    print(name, addr, target, data)
" | while read -r name addr target data; do
  # Already live on the forked network (deploy-stage.sh): replaying the CREATE2 call would revert.
  if [ "$(cast codesize "$addr" --rpc-url "$RPC")" != "0" ]; then
    echo "  ok   $name already deployed"
    continue
  fi
  send "$DEPLOYER" "$target" "$data" "CREATE2 deployment of $name"
done

GOV=$(cast call "$(toml_get state_transition.chain_type_manager_proxy)" 'owner()(address)' --rpc-url "$RPC")
GOV_OWNER=$(toml_get governance_operations.governance_owner)
for STAGE in 0 1 2; do
  send "$GOV_OWNER" "$GOV" "$(toml_get governance_operations.stage${STAGE}_schedule_calldata)" "stage $STAGE scheduleTransparent"
  send "$GOV_OWNER" "$GOV" "$(toml_get governance_operations.stage${STAGE}_execute_calldata)" "stage $STAGE execute"
done
