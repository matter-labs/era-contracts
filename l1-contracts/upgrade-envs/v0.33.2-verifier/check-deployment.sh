#!/usr/bin/env bash
# Read-only check of the v0.33.2 verifier-only deployments of one environment on a real chain: the four CREATE2
# contracts of `ecosystem.toml` exist, the verifier carries the new VK in the env's flavour, and the stage
# validator and the governance timer are wired to this CTM and its owner. Sends no transaction.
#
# The generate / deploy pipeline runs it as this upgrade's `verify_chain` (see upgrade.toml) from l1-contracts/,
# with L1_RPC_URL, ECOSYSTEM_TOML and UPGRADE_ENV set. By hand:
#   L1_RPC_URL=<sepolia rpc> ./check-deployment.sh <env>
set -uo pipefail

: "${L1_RPC_URL:?set L1_RPC_URL to the chain to check}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV=${1:-${UPGRADE_ENV:?usage: check-deployment.sh <env>, or set UPGRADE_ENV}}
OUT=${ECOSYSTEM_TOML:-$HERE/output/$ENV/ecosystem.toml}
FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }
chk() { [ "$(echo "$2" | tr A-F a-f)" = "$(echo "$3" | tr A-F a-f)" ] && echo "  OK   $1" || fail "$1: expected $3, got $2"; }
toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[2],'rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(str(v).lower() if isinstance(v, bool) else v)" "$1" "${2:-$OUT}"; }
call() { cast call "$@" --rpc-url "$L1_RPC_URL" | awk '{print $1}'; }

CTM=$(toml_get state_transition.chain_type_manager_proxy)
PLONK=$(toml_get state_transition.verifier_plonk_addr)
VERIFIER=$(toml_get state_transition.verifier_addr)
VALIDATOR=$(toml_get deployed_addresses.upgrade_stage_validator)
TIMER=$(toml_get deployed_addresses.l1_governance_upgrade_timer)
OLD=$(toml_get contracts_config.old_protocol_version)
NEW=$(toml_get contracts_config.new_protocol_version)

for PAIR in "ZKsyncOSVerifierPlonk:$PLONK" "verifier:$VERIFIER" "UpgradeStageValidator:$VALIDATOR" "GovernanceUpgradeTimer:$TIMER"; do
  [ "$(cast codesize "${PAIR#*:}" --rpc-url "$L1_RPC_URL")" != "0" ] \
    && echo "  OK   ${PAIR%%:*} deployed at ${PAIR#*:}" || fail "${PAIR%%:*}: no code at ${PAIR#*:}"
done
chk "verifier VK" "$(call "$VERIFIER" 'verificationKeyHash()(bytes32)')" "$(toml_get verification_key.new_vk_hash)"
chk "verifier wraps verifier_plonk" "$(call "$VERIFIER" 'PLONK_VERIFIER()(address)')" "$PLONK"
chk "verifier flavour (testnet_verifier)" "$(call "$VERIFIER" 'IS_TESTNET_VERIFIER()(bool)')" \
  "$(toml_get testnet_verifier "$HERE/$ENV.toml")"
chk "stage validator CTM" "$(call "$VALIDATOR" 'CHAIN_TYPE_MANAGER()(address)')" "$CTM"
chk "stage validator version" "$(call "$VALIDATOR" 'NEW_PROTOCOL_VERSION()(uint256)')" "$NEW"
chk "timer governance = CTM owner" "$(call "$TIMER" 'TIMER_GOVERNANCE()(address)')" "$(call "$CTM" 'owner()(address)')"
chk "timer initial delay" "$(call "$TIMER" 'INITIAL_DELAY()(uint256)')" \
  "$(toml_get governance_upgrade_timer_initial_delay "$HERE/$ENV.toml")"

# The governance stages may or may not have run; either is a valid state for the deployment.
VERSION=$(call "$CTM" 'protocolVersion()(uint256)')
if [ "$VERSION" = "$NEW" ]; then
  echo "CTM is on the new version: the governance stages have run"
  chk "CTM verifier for the new version" "$(call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$NEW")" "$VERIFIER"
else
  chk "CTM still on the old version (governance not run yet)" "$VERSION" "$OLD"
fi

echo
if [ "$FAILED" = "0" ]; then
  echo "DEPLOYMENT CHECK PASSED"
else
  echo "DEPLOYMENT CHECK FAILED"
  exit 1
fi
