#!/usr/bin/env bash
# The ecosystem-upgrade workflows' protocol-ops commands, end to end, on the anvil-interop fixture the
# current release upgrades from (env preset `anvil-interop`):
#   generate  `rehearse-upgrade` and the simulator export (generate-ecosystem-upgrade-calldata.yaml);
#   handoff   `replay-bundle --fork-url` (its verify-bundle-handoff job);
#   deploy    `verify-bundle`, `upgrade-broadcast` with the deployer key (deploy-ecosystem-upgrade.yaml),
#             then `replay-bundle --verify-only` on the result;
#   govern    the simulator export's governance calls, as the vote executes them;
#   chain     a partner's chain operations, `set-upgrade-timestamp` and `add-validator`, run the way
#             docs/protocol-ops-for-partners.md runs them, with their bundles sent and their effect
#             checked on L1. Not `chain upgrade`: the fixture's chains still have the previous
#             upgrade's L2 transaction pending, which an L1-only fixture can't finalize.
# The commands only: every phase runs this checkout in one unpushed image, so the bundle names no
# registry digest, and the workflows' own digest and commit checks don't run here. The bundle is still
# copied out and mounted read-only, as their downloaded artifact is.
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
# The chain the chain phase operates, and what it sets.
readonly CHAIN_ID=10
readonly UPGRADE_TIMESTAMP=1900000000
readonly VALIDATOR=0x1111111111111111111111111111111111111111

po() {
  if [[ -n "${PROTOCOL_OPS_TAG:-}" ]]; then
    ./protocol-ops.sh --tag "$PROTOCOL_OPS_TAG" "$@"
  else
    ./protocol-ops.sh "$@"
  fi
}

# `protocol_ops chain $2… --out $1` on CHAIN_ID as a partner runs it: `docker run` on the image, with
# its own configs and an empty `out/` mounted (docs/protocol-ops-for-partners.md). From this checkout
# without an image.
chain_op() {
  local out=$1 image
  shift
  mkdir "$out"
  set -- "$@" --env "$ENV" --chain-id "$CHAIN_ID" --l1-rpc-url "$L1"
  if [[ -z "${PROTOCOL_OPS_TAG:-}" ]]; then
    ./protocol-ops.sh chain "$@" --out "$out"
    return
  fi
  if [[ "$PROTOCOL_OPS_TAG" == sha256:* ]]; then
    image="ghcr.io/matter-labs/protocol-ops@$PROTOCOL_OPS_TAG"
  else
    image="ghcr.io/matter-labs/protocol-ops:$PROTOCOL_OPS_TAG"
  fi
  docker run --rm --platform linux/amd64 --network=host -v "$out:/out" "$image" \
    protocol_ops chain "$@" --out /out
}

# Sends as `$1`, impersonated and funded.
send_as() {
  local from=$1
  shift
  cast rpc anvil_setBalance "$from" 0x56BC75E2D63100000 --rpc-url "$L1" >/dev/null
  cast send --from "$from" --unlocked --rpc-url "$L1" "$@" >/dev/null
}

# Sends the bundles in `$1/manifest.json`, in order, each from the account it names (EXECUTE.md's way).
send_bundles() {
  local target file to value data
  while read -r target file; do
    while read -r to value data; do
      send_as "$target" "$to" "$data" --value "$value"
    done < <(jq -r '.transactions[] | "\(.to) \(.value) \(.data)"' "$1/$file")
  done < <(jq -r '.bundles[] | "\(.target) \(.file)"' "$1/manifest.json")
}

fixture="l1-contracts/test/anvil-interop/chain-states/$(jq -r .upgradeSourceStateVersion \
  l1-contracts/test/anvil-interop/config/anvil-config.json)"
addresses="$fixture/addresses.json"
bridgehub="$(jq -r .l1Addresses.bridgehub "$addresses")"
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
require_named "$preset" "$bridgehub"
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
po ecosystem rehearse-upgrade --env "$ENV" --fork-url "$L1" --deployer-address "$DEPLOYER"
out="${input%/*}/output/$ENV"
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
   and (has("contracts_worktree_dirty") | not) and (.zk_governance_commit | length) == 40' \
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

echo "== govern"
while read -r from to data value; do
  send_as "$from" "$to" "$data" --value "${value}ether"
done < <(jq -r '.[] | select(.tag == "governance") | "\(.from) \(.to) \(.data) \(.value)"' \
  "$out/transaction-simulator.json")

echo "== chain $CHAIN_ID"
# The fixture's chains have an EOA admin; the commands need a ChainAdmin, as `RegisterZKChain`
# deploys one (Ownable, owned by that EOA). The fixture's own ChainAdminOwnable takes the chain.
chain_admin="$(jq -r .ctmAddresses.chainAdmin "$addresses")"
diamond="$(cast call "$bridgehub" 'getZKChain(uint256)(address)' "$CHAIN_ID" --rpc-url "$L1")"
admin="$(cast call "$diamond" 'getAdmin()(address)' --rpc-url "$L1")"
if [[ "$admin" != "$chain_admin" ]]; then
  send_as "$admin" "$diamond" 'setPendingAdmin(address)' "$chain_admin"
  send_as "$(cast call "$chain_admin" 'owner()(address)' --rpc-url "$L1")" "$chain_admin" \
    'multicall((address,uint256,bytes)[],bool)' "[($diamond,0,$(cast calldata 'acceptAdmin()'))]" true
fi

# INC-38's call: the timestamp must land on the version the chain upgrades from.
chain_op "$work/set-upgrade-timestamp" set-upgrade-timestamp --upgrade-timestamp "$UPGRADE_TIMESTAMP"
send_bundles "$work/set-upgrade-timestamp"
version="$(cast call "$ctm" 'getProtocolVersion(uint256)(uint256)' "$CHAIN_ID" --rpc-url "$L1" | cut -d' ' -f1)"
server_notifier="$(cast call "$ctm" 'serverNotifierAddress()(address)' --rpc-url "$L1")"
scheduled="$(cast call "$server_notifier" 'protocolVersionToUpgradeTimestamp(uint256,uint256)(uint256)' \
  "$CHAIN_ID" "$version" --rpc-url "$L1" | cut -d' ' -f1)"
if [[ "$scheduled" != "$UPGRADE_TIMESTAMP" ]]; then
  echo "error: chain $CHAIN_ID's upgrade timestamp for its version $version is $scheduled, not $UPGRADE_TIMESTAMP" >&2
  exit 1
fi

chain_op "$work/add-validator" add-validator --validator-address "$VALIDATOR"
send_bundles "$work/add-validator"
timelock="$(cast call "$ctm" 'validatorTimelockPostV29()(address)' --rpc-url "$L1")"
for role in COMMITTER_ROLE PROVER_ROLE EXECUTOR_ROLE; do
  if [[ "$(cast call "$timelock" 'hasRoleForChainId(uint256,bytes32,address)(bool)' "$CHAIN_ID" \
    "$(cast keccak "$role")" "$VALIDATOR" --rpc-url "$L1")" != true ]]; then
    echo "error: $VALIDATOR has no $role for chain $CHAIN_ID" >&2
    exit 1
  fi
done
echo "Release flow passed"
