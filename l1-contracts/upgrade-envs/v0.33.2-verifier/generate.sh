#!/usr/bin/env bash
# Regenerate the v0.33.2 verifier-only upgrade artifacts of one environment (`stage`, `testnet`):
#   1. ZKsyncOSVerifierOnlyUpgrade.prepare -> output/<env>/ecosystem.toml (simulation only, never broadcasts)
#   2. for an ecosystem governed by a ProtocolUpgradeHandler, the emergency proposal running stages 0-2
#      (output/<env>/emergency-upgrade-board.json) and its runbook (output/<env>/EXECUTE.md)
#   3. protocol_ops governance-toml-to-simulator -> the transaction-simulator scenario
#
# Steps 2 and 3 need the CREATE2 deployments on the network: they are not part of the scenario or the
# proposal, so after a fresh prepare run deploy.sh <env> and then this script again (prepare is
# deterministic and rewrites the same ecosystem.toml).
#
# Needs: foundry-zksync v0.1.5 (the CI pin) first on PATH, python3, and a release build of protocol-ops
# (`cd protocol-ops && cargo build --release`).
# Usage: L1_RPC=<sepolia rpc> ./generate.sh <env> [scenario-date, default: today]
set -euo pipefail

ENV=${1:?usage: generate.sh <env> [scenario-date]}
: "${L1_RPC:?set L1_RPC to a Sepolia RPC}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
L1=$(cd "$HERE/../.." && pwd)
REPO=$(cd "$L1/.." && pwd)
ENV_OUT_REL=/upgrade-envs/v0.33.2-verifier/output/$ENV
OUT_REL=$ENV_OUT_REL/ecosystem.toml
OUT=$L1$OUT_REL
DATE=${2:-$(date -u +%Y-%m-%d)}
SCENARIO=$HERE/output/$ENV/simulator/$DATE-v0.33.2-verifier-$ENV-1-ecosystem.json
PROTOCOL_OPS=${PROTOCOL_OPS:-$REPO/protocol-ops/target/release/protocol_ops}

mkdir -p "$(dirname "$OUT")" "$(dirname "$SCENARIO")"
rm -f "$OUT"
cd "$L1"
forge script deploy-scripts/upgrade/verifier-only/ZKsyncOSVerifierOnlyUpgrade.s.sol:ZKsyncOSVerifierOnlyUpgrade \
  --sig 'prepare(string,string)' "/upgrade-envs/v0.33.2-verifier/$ENV.toml" "$OUT_REL" --rpc-url "$L1_RPC"

toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }

# The governance calls name the deployed contracts, so they must exist on the network being forked.
for KEY in state_transition.verifier_plonk_addr state_transition.verifier_addr \
  deployed_addresses.upgrade_stage_validator deployed_addresses.l1_governance_upgrade_timer; do
  [ "$(cast codesize "$(toml_get $KEY)" --rpc-url "$L1_RPC")" != "0" ] \
    || { echo "$KEY $(toml_get $KEY) has no code: run deploy.sh $ENV, then this script again"; exit 1; }
done

if ! python3 -c "import tomllib,sys; sys.exit(0 if tomllib.load(open('$HERE/$ENV.toml','rb'))['owner_is_governance'] else 1)"; then
  # The timer delay is 0, so stages 0-2 can run as one emergency proposal.
  forge script deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol:EmergencyStageUpgradeCalldata \
    --sig 'emergencyUpgradeAllStages(string,string,string)' "/upgrade-envs/permanent-values/$ENV.toml" \
    "$OUT_REL" "$ENV_OUT_REL/emergency-upgrade-board.json" --rpc-url "$L1_RPC"
  "$PROTOCOL_OPS" dev execution-runbook --input "$HERE/output/$ENV/emergency-upgrade-board.json" --env "$ENV" \
    --upgrade v0.33.2-verifier --check-fork-url "$L1_RPC"
fi

"$PROTOCOL_OPS" ecosystem governance-toml-to-simulator \
  --governance-toml "$OUT" \
  --from "$(cast call "$(toml_get state_transition.chain_type_manager_proxy)" 'owner()(address)' --rpc-url "$L1_RPC")" \
  --network sepolia \
  --descriptions "$HERE/sim-descriptions-$ENV.toml" \
  --ack test_upgrade_chain_zkos \
  --out "$SCENARIO"

# The transaction-simulator no longer handles `ack_` markers: an absent checked tag is an inert
# `alreadyExecuted` entry carrying the tag itself. The per-chain scenarios cover the upgrade.
python3 - "$SCENARIO" "$DATE" "$ENV" <<'PY'
import json, sys
path, date, env = sys.argv[1:]
scenario = json.load(open(path))
for tx in scenario:
    if tx["tag"] == "ack_test_upgrade_chain_zkos":
        tx.update({"to": tx["from"], "data": "0x", "value": "0", "tag": "test_upgrade_chain_zkos", "alreadyExecuted": True,
                   "description": "Placeholder: test_upgrade_chain_zkos is absent from this artifact (v0.33.2 emits none). "
                                  f"The real per-chain upgrades are the {date}-v0.33.2-verifier-{env}-2-chain-*.json "
                                  "scenarios (tag chain_upgrade_<chainId>)."})
json.dump(scenario, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
echo "scenario: $SCENARIO"
