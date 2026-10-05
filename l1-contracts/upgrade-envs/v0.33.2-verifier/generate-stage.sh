#!/usr/bin/env bash
# Regenerate the v0.33.2 verifier-only upgrade artifacts for the ZKsync OS stage ecosystem:
#   1. ZKsyncOSVerifierOnlyUpgrade.prepare -> output/stage/ecosystem.toml (simulation only, never broadcasts)
#   2. protocol_ops governance-toml-to-simulator -> the transaction-simulator scenario, with the two
#      CREATE2 verifier deployments prepended (tag `deploy_verifier`, sent by `[deploy_calls].deployer`)
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
SCENARIO=$HERE/output/stage/simulator/$DATE-v0.33.2-verifier-stage.json
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
  --from "$(toml_get contracts_config.governance)" \
  --network sepolia \
  --descriptions "$HERE/sim-descriptions.toml" \
  --out "$SCENARIO"

# The deployments go first: stage 1 names the verifier they create.
DEPLOY_JSON=$(cast abi-decode --json --input 'f((address,uint256,bytes)[])' "$(toml_get deploy_calls.calls)")
python3 - "$SCENARIO" "$(toml_get deploy_calls.deployer)" "$(toml_get contracts_config.verifier_plonk)" \
  "$(toml_get contracts_config.verifier)" "$DEPLOY_JSON" <<'PY'
import json, sys
path, deployer, plonk, verifier, calls = sys.argv[1:]
calls = json.loads(calls)[0]
assert len(calls) == 2, calls
names = [
    f"Deploy ZKsyncOSVerifierPlonk (v0.33.2 VK) to {plonk} via the CREATE2 factory",
    f"Deploy ZKsyncOSTestnetVerifier wrapping it to {verifier} via the CREATE2 factory",
]
deploys = []
for i, ((target, value, data), desc) in enumerate(zip(calls, names)):
    assert int(str(value), 0) == 0
    tx = {"description": desc, "network": "sepolia", "from": deployer.lower(), "to": target.lower(),
          "data": data, "value": "0"}
    if i == 0:
        tx["valueToMint"] = "1"
    tx["tag"] = "deploy_verifier"
    deploys.append(tx)
scenario = json.load(open(path))
json.dump(deploys + scenario, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
echo "scenario: $SCENARIO"
