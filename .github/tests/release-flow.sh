#!/usr/bin/env bash
# The ecosystem-upgrade workflows' protocol-ops commands, end to end, on the anvil-interop fixture the
# current release upgrades from (env preset `anvil-interop`):
#   generate  `rehearse-upgrade` and the simulator export (generate-ecosystem-upgrade-calldata.yaml);
#   handoff   `verify-bundle` and `replay-bundle --fork-url` (its verify-bundle-handoff job);
#   deploy    `upgrade-broadcast` with the deployer key (deploy-ecosystem-upgrade.yaml), then
#             `replay-bundle --verify-only` on the result.
# The bundle travels as the workflows' artifact does: copied out, mounted read-only.
#
# Runs in the image PROTOCOL_OPS_TAG names (build-docker.yaml; Linux, for the host network), else from
# this checkout. Needs anvil, cast and jq.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

readonly ENV=anvil-interop
# Not the interop harness's L1 port, so a running local setup is left alone.
readonly L1=http://127.0.0.1:19545
# Anvil's first account, the fixture's deployer.
readonly DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
readonly DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
readonly EIP1967_ADMIN_SLOT=0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103

po() {
  if [[ -n "${PROTOCOL_OPS_TAG:-}" ]]; then
    ./protocol-ops.sh --tag "$PROTOCOL_OPS_TAG" "$@"
  else
    ./protocol-ops.sh "$@"
  fi
}

# Sends as `$1`, impersonated and funded.
send_as() {
  local from=$1
  shift
  cast rpc anvil_setBalance "$from" 0x56BC75E2D63100000 --rpc-url "$L1" >/dev/null
  cast send --from "$from" --unlocked --rpc-url "$L1" "$@" >/dev/null
}

fixture="l1-contracts/test/anvil-interop/chain-states/$(jq -r .upgradeSourceStateVersion \
  l1-contracts/test/anvil-interop/config/anvil-config.json)"
addresses="$fixture/addresses.json"
preset="l1-contracts/upgrade-envs/permanent-values/$ENV.toml"
for address in "$(jq -r .l1Addresses.bridgehub "$addresses")" "$(jq -r .ctmAddresses.chainTypeManager "$addresses")"; do
  if ! grep -qi "\"$address\"" "$preset"; then
    echo "error: $preset does not name $address of $addresses: copy the fixture's addresses into it" >&2
    exit 1
  fi
done

echo "== L1: $fixture"
work="$(mktemp -d)"
gunzip -c "$fixture/31337.json.gz" >"$work/l1-state.json"
anvil --port "${L1##*:}" --chain-id 31337 --accounts 10 --balance 10000 --gas-limit 100000000 \
  --block-base-fee-per-gas 0 --auto-impersonate --load-state "$work/l1-state.json" >"$work/anvil.log" 2>&1 &
anvil_pid=$!
trap 'kill "$anvil_pid"' EXIT
for _ in $(seq 60); do
  cast chain-id --rpc-url "$L1" >/dev/null 2>&1 && break
  sleep 1
done
cast chain-id --rpc-url "$L1" >/dev/null

# Production-shaped ownership, as the upgrade test's `transferL1Ownership`
# (l1-contracts/test/anvil-interop/src/helpers/pipeline-upgrade-runner.ts): governance owns the
# ecosystem contracts and the CTM, and an EOA the CTM's ProxyAdmin.
governance="$(jq -r .l1Addresses.governance "$addresses")"
ctm="$(jq -r .ctmAddresses.chainTypeManager "$addresses")"
for contract in $(jq -r '.l1Addresses | .bridgehub, .l1SharedBridge, .l1NativeTokenVault, .l1NullifierProxy // empty' \
  "$addresses") "$ctm"; do
  owner="$(cast call "$contract" 'owner()(address)' --rpc-url "$L1")"
  if [[ "$owner" != "$governance" ]]; then
    send_as "$owner" "$contract" 'transferOwnership(address)' "$governance"
    send_as "$governance" "$contract" 'acceptOwnership()'
  fi
done
proxy_admin="$(cast parse-bytes32-address "$(cast storage "$ctm" "$EIP1967_ADMIN_SLOT" --rpc-url "$L1")")"
owner="$(cast call "$proxy_admin" 'owner()(address)' --rpc-url "$L1")"
if [[ "$(cast code "$owner" --rpc-url "$L1")" != 0x ]]; then
  send_as "$owner" "$proxy_admin" 'transferOwnership(address)' "$DEPLOYER"
fi

echo "== generate"
rm -rf l1-contracts/upgrade-envs/*/output/"$ENV"
po ecosystem rehearse-upgrade --env "$ENV" --fork-url "$L1" --deployer-address "$DEPLOYER"
outputs=(l1-contracts/upgrade-envs/*/output/"$ENV")
out="${outputs[0]}"
po ecosystem governance-toml-to-simulator --env "$ENV" --include-manifest "$out/prepare/manifest.json" \
  --camp-a-signers "$DEPLOYER" --emit-sim-inputs "$out/sim-inputs"
po ecosystem governance-toml-to-simulator --env "$ENV" --out "$out/transaction-simulator.json"

echo "== handoff"
bundle="$work/bundle"
result="$work/result"
cp -R "$out/deploy-bundle" "$bundle"
mkdir "$result"
export EXTRA_MOUNTS="$bundle:$bundle:ro $result:$result"
po ecosystem verify-bundle "$bundle"
po ecosystem replay-bundle --bundle "$bundle" --fork-url "$L1"
if [[ -n "${PROTOCOL_OPS_TAG:-}" ]] && ! jq -e --arg tag "$PROTOCOL_OPS_TAG" --arg commit "$(git rev-parse HEAD)" \
  '(.protocol_ops_image.reference | endswith($tag)) and .contracts_commit == $commit
   and .contracts_worktree_dirty == false and (.zk_governance_commit | length) == 40' \
  "$bundle/bundle-metadata.json" >/dev/null; then
  echo "error: $bundle/bundle-metadata.json does not record the image and its commits" >&2
  exit 1
fi

echo "== deploy"
po ecosystem upgrade-broadcast --manifest "$bundle/prepare/manifest.json" --l1-rpc-url "$L1" \
  --key "$DEPLOYER=$DEPLOYER_KEY" --skip-unkeyed --max-gas-price-gwei 500 --out "$result/deploy-executed.json"
[[ -s "$result/transactions.txt" ]]
po ecosystem replay-bundle --bundle "$bundle" --rpc "$L1" --verify-only
echo "Release flow passed"
