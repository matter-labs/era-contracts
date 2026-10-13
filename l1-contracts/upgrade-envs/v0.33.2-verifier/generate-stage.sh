#!/usr/bin/env bash
# Regenerate the v0.33.2 verifier-only upgrade artifacts for the ZKsync OS stage ecosystem:
#   1. ZKsyncOSVerifierOnlyUpgrade.prepare -> output/stage/ecosystem.toml (simulation only, never broadcasts)
#   2. protocol_ops governance-toml-to-simulator -> the transaction-simulator scenario
#
# The CREATE2 deployments are not in the scenario: they are live on Sepolia (deploy-stage.sh,
# output/stage/transactions.txt), so the fork already has them. This script refuses to emit a
# scenario while any of them is missing.
#
# Needs: foundry-zksync v0.1.5 (the CI pin) on PATH, python3, and a release build of protocol-ops
# (`cd protocol-ops && cargo build --release`).
# Usage: L1_RPC=<sepolia rpc> ./generate-stage.sh [scenario-date, default: today]
set -euo pipefail

: "${L1_RPC:?set L1_RPC to a Sepolia RPC}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
L1=$(cd "$HERE/../.." && pwd)
REPO=$(cd "$L1/.." && pwd)
OUT_REL=/upgrade-envs/v0.33.2-verifier/output/stage/ecosystem.toml
OUT=$L1$OUT_REL
DATE=${1:-$(date -u +%Y-%m-%d)}
SCENARIO=$HERE/output/stage/simulator/$DATE-v0.33.2-verifier-stage-1-ecosystem.json
PROTOCOL_OPS=${PROTOCOL_OPS:-$REPO/protocol-ops/target/release/protocol_ops}

mkdir -p "$(dirname "$OUT")" "$(dirname "$SCENARIO")"
rm -f "$OUT"
cd "$L1"
forge script deploy-scripts/upgrade/verifier-only/ZKsyncOSVerifierOnlyUpgrade.s.sol:ZKsyncOSVerifierOnlyUpgrade \
  --sig 'prepare(string,string)' /upgrade-envs/v0.33.2-verifier/stage.toml "$OUT_REL" --rpc-url "$L1_RPC"

toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }

"$PROTOCOL_OPS" ecosystem governance-toml-to-simulator \
  --governance-toml "$OUT" \
  --from "$(cast call "$(toml_get state_transition.chain_type_manager_proxy)" 'owner()(address)' --rpc-url "$L1_RPC")" \
  --network sepolia \
  --descriptions "$HERE/sim-descriptions.toml" \
  --ack test_upgrade_chain_zkos \
  --out "$SCENARIO"

# The governance calls name the deployed contracts, so they must exist on the network being forked.
for KEY in state_transition.verifier_plonk_addr state_transition.verifier_addr \
  deployed_addresses.upgrade_stage_validator deployed_addresses.l1_governance_upgrade_timer; do
  [ "$(cast codesize "$(toml_get $KEY)" --rpc-url "$L1_RPC")" != "0" ] \
    || { echo "$KEY $(toml_get $KEY) has no code: run deploy-stage.sh first"; exit 1; }
done
echo "scenario: $SCENARIO"
