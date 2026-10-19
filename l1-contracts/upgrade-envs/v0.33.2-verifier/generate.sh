#!/usr/bin/env bash
# Regenerate the v0.33.2 verifier-only upgrade artifacts of one environment (`stage3`, `testnet`):
#   1. `protocol_ops ecosystem rehearse-upgrade --upgrade v0.33.2-verifier`, the command the
#      generate-ecosystem-upgrade-calldata workflow runs (see upgrade.toml): on a fork, the prepare
#      (ZKsyncOSVerifierOnlyUpgrade) -> output/<env>/ecosystem.toml and the deploy bundle
#      (output/<env>/deploy-bundle/, not committed); the bundle replayed; the governance txs (testnet: the
#      `[execution]` script, stage3: `[governance_operations]`) -> output/<env>/execution.json and its
#      runbook output/<env>/EXECUTE.md; then rehearse.sh <env>
#   2. protocol_ops governance-toml-to-simulator -> output/<env>/simulator/<date>-v0.33.2-verifier-<env>-1-ecosystem.json
#
# Nothing is sent to the network. Once the deployments are live, the prepare deploys nothing at the tip and the
# pipeline refuses the empty bundle: set FORK_BLOCK to a block before the first deployment (stage3: 11854782,
# testnet: 11926704). The CREATE2 addresses do not depend on it.
#
# Needs: foundry-zksync v0.1.5 (the CI pin) first on PATH and upstream anvil >= 1.8.3 after it (Sepolia runs
# Glamsterdam), python3, and a release build of protocol-ops (`cd protocol-ops && cargo build --release`).
# Usage: L1_RPC=<sepolia rpc> [FORK_BLOCK=<n>] [DEPLOYER_ADDRESS=<eoa>] ./generate.sh <env> [scenario-date, default: today]
set -euo pipefail

ENV=${1:?usage: generate.sh <env> [scenario-date]}
: "${L1_RPC:?set L1_RPC to a Sepolia RPC}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
L1=$(cd "$HERE/../.." && pwd)
REPO=$(cd "$L1/.." && pwd)
OUT=$HERE/output/$ENV/ecosystem.toml
DATE=${2:-$(date -u +%Y-%m-%d)}
SCENARIO=$HERE/output/$ENV/simulator/$DATE-v0.33.2-verifier-$ENV-1-ecosystem.json
PROTOCOL_OPS=${PROTOCOL_OPS:-$REPO/protocol-ops/target/release/protocol_ops}

toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[2],'rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1" "${2:-$OUT}"; }

# The deployer only sends the CREATE2 factory calls; no address depends on it.
DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS:-$(toml_get deployer "$HERE/$ENV.toml")}
args=(--upgrade v0.33.2-verifier --env "$ENV" --fork-url "$L1_RPC" --deployer-address "$DEPLOYER_ADDRESS")
[ -z "${FORK_BLOCK:-}" ] || args+=(--fork-block "$FORK_BLOCK")
(cd "$REPO" && "$PROTOCOL_OPS" ecosystem rehearse-upgrade "${args[@]}")

BLOCK=()
[ -z "${FORK_BLOCK:-}" ] || BLOCK=(--block "$FORK_BLOCK")
mkdir -p "$(dirname "$SCENARIO")"
"$PROTOCOL_OPS" ecosystem governance-toml-to-simulator \
  --governance-toml "$OUT" \
  --from "$(cast call "$(toml_get state_transition.chain_type_manager_proxy)" 'owner()(address)' "${BLOCK[@]}" --rpc-url "$L1_RPC")" \
  --network sepolia \
  --descriptions "$HERE/sim-descriptions-$ENV.toml" \
  --ack test_upgrade_chain_zkos \
  --out "$SCENARIO"

echo "scenario: $SCENARIO"
