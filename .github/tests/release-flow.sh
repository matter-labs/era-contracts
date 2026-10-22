#!/usr/bin/env bash
# The ecosystem-upgrade workflows' protocol-ops commands, end to end, on the anvil-interop fixture the
# current release upgrades from (env preset `anvil-interop`):
#   generate  `rehearse-upgrade` and the simulator export (generate-ecosystem-upgrade-calldata.yaml);
#   handoff   `replay-bundle --fork-url` (its verify-bundle-handoff job);
#   deploy    `verify-bundle`, `upgrade-broadcast` with the deployer key (deploy-ecosystem-upgrade.yaml),
#             then `replay-bundle --verify-only` on the result.
# The commands only: every phase runs this checkout in one unpushed image, so the bundle names no
# registry digest; the workflows' digest and commit checks are bundle-image-checks.test.cjs. The bundle
# is still copied out and mounted read-only, as their downloaded artifact is.
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
governance="$(jq -r .l1Addresses.governance "$addresses")"
ctm="$(jq -r .ctmAddresses.chainTypeManager "$addresses")"
preset="l1-contracts/upgrade-envs/permanent-values/$ENV.toml"
input="$(printf '%s\n' l1-contracts/upgrade-envs/v*/"$ENV".toml | sort -V | tail -1)"
# The env must name the fixture's values; `yarn new-release` moves the fixture.
require_named() {
  if ! grep -qi "\"$2\"" "$1"; then
    echo "error: $1 does not name $2 of $addresses: copy the fixture's values into it" >&2
    exit 1
  fi
}
require_named "$preset" "$(jq -r .l1Addresses.bridgehub "$addresses")"
require_named "$preset" "$ctm"
require_named "$preset" "$(jq -r .zkToken.assetId "$addresses")"
require_named "$input" "$governance"
require_named "$input" "$ctm"

echo "== L1: $fixture"
if cast chain-id --rpc-url "$L1" >/dev/null 2>&1; then
  echo "error: $L1 is in use" >&2
  exit 1
fi
work="$(mktemp -d)"
gunzip -c "$fixture/31337.json.gz" >"$work/l1-state.json"
anvil --port "${L1##*:}" --chain-id 31337 --accounts 10 --balance 10000 --gas-limit 100000000 \
  --block-base-fee-per-gas 0 --auto-impersonate --load-state "$work/l1-state.json" >"$work/anvil.log" 2>&1 &
anvil_pid=$!
trap 'kill "$anvil_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 60); do
  cast chain-id --rpc-url "$L1" >/dev/null 2>&1 && break
  if ! kill -0 "$anvil_pid" 2>/dev/null; then
    cat "$work/anvil.log" >&2
    exit 1
  fi
  sleep 1
done
cast chain-id --rpc-url "$L1" >/dev/null

# Production-shaped ownership, as the upgrade test's `transferL1Ownership`
# (l1-contracts/test/anvil-interop/src/helpers/pipeline-upgrade-runner.ts): governance owns the
# ecosystem contracts and the CTM, and an EOA the CTM's ProxyAdmin.
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
if ! jq -e '.bundles' "$out/sim-inputs/manifest.json" >/dev/null ||
  ! jq -e --arg from "$governance" 'any(.[]; (.from | ascii_downcase) == ($from | ascii_downcase))' \
    "$out/transaction-simulator.json" >/dev/null; then
  echo "error: the simulator export has no sim-inputs manifest or no governance call" >&2
  exit 1
fi

echo "== handoff"
bundle="$work/bundle"
result="$work/result"
cp -R "$out/deploy-bundle" "$bundle"
mkdir "$result"
export EXTRA_MOUNTS="$bundle:$bundle:ro $result:$result"
po ecosystem replay-bundle --bundle "$bundle" --fork-url "$L1"
if [[ -n "${PROTOCOL_OPS_TAG:-}" ]] && ! jq -e --arg tag "$PROTOCOL_OPS_TAG" --arg commit "$(git rev-parse HEAD)" \
  '(.protocol_ops_image.reference | endswith($tag)) and .contracts_commit == $commit
   and .contracts_worktree_dirty == false and (.zk_governance_commit | length) == 40' \
  "$bundle/bundle-metadata.json" >/dev/null; then
  echo "error: $bundle/bundle-metadata.json does not record the image and its commits" >&2
  exit 1
fi

echo "== deploy"
po ecosystem verify-bundle "$bundle"
po ecosystem upgrade-broadcast --manifest "$bundle/prepare/manifest.json" --l1-rpc-url "$L1" \
  --key "$DEPLOYER=$DEPLOYER_KEY" --skip-unkeyed --max-gas-price-gwei 500 --out "$result/deploy-executed.json"
if [[ ! -s "$result/transactions.txt" ]]; then
  echo "error: upgrade-broadcast recorded no transactions in $result/transactions.txt" >&2
  exit 1
fi
po ecosystem replay-bundle --bundle "$bundle" --rpc "$L1" --verify-only
echo "Release flow passed"
