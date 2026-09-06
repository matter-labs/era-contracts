#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
ZERO_BYTES32="0x0000000000000000000000000000000000000000000000000000000000000000"
NEW_PROTOCOL_VERSION="124554051588"
OLD_PROTOCOL_VERSION_DEADLINE="0"

usage() {
  cat <<'EOF'
Usage:
  scripts/set_ctm_protocol_version_temporarily.sh

Required env vars:
  CTM_PROXY                 Address of the CTM proxy.
  RPC_URL                   RPC URL for the target chain.
  OWNER_PRIVATE_KEY         Private key of the EOA that owns Governance.

What it does:
  1. Reads the current CTM protocol version and owner.
  2. Verifies the CTM owner is a Governance contract owned by the provided EOA.
  3. Verifies the same Governance also owns the CTM Bridgehub.
  4. Schedules and executes a Governance operation that calls, in order:
     - `Bridgehub.pauseMigration()`
     - `setNewVersionUpgrade(emptyDiamondCut, oldProtocolVersion, 0, 124554051588)`
     - `Bridgehub.unpauseMigration()`

Notes:
  - The diamond cut is empty:
    `([], address(0), 0x)`
  - The old version deadline is set to `0`.
  - The new version deadline is set by CTM itself to `type(uint256).max`.
  - The script will leave migrations unpaused at the end of the multicall.
EOF
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

print_and_run() {
  printf '+' >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
  "$@"
}

normalize_address() {
  cast to-check-sum-address "$1"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_uint_output() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/^([0-9]+).*/\1/; s/^(0x[0-9a-fA-F]+).*/\1/')"
  if [[ ! "$value" =~ ^([0-9]+|0x[0-9a-fA-F]+)$ ]]; then
    echo "Could not normalize uint output: $1" >&2
    exit 1
  fi
  printf '%s' "$value"
}

main() {
  require_env CTM_PROXY
  require_env RPC_URL
  require_env OWNER_PRIVATE_KEY

  local ctm_proxy owner_address governance governance_owner governance_min_delay
  local current_protocol_version updated_protocol_version migration_paused bridgehub bridgehub_owner
  local pause_migration_calldata unpause_migration_calldata set_new_version_calldata operation_args
  local current_protocol_version_uint256 old_protocol_version_deadline_uint256 new_protocol_version_uint256

  cd "$ROOT_DIR"

  ctm_proxy="$(normalize_address "$CTM_PROXY")"
  owner_address="$(cast wallet address --private-key "$OWNER_PRIVATE_KEY")"

  governance="$(normalize_address "$(cast call "$ctm_proxy" "owner()(address)" --rpc-url "$RPC_URL")")"
  current_protocol_version="$(cast call "$ctm_proxy" "protocolVersion()(uint256)" --rpc-url "$RPC_URL")"
  current_protocol_version="$(normalize_uint_output "$current_protocol_version")"
  bridgehub="$(normalize_address "$(cast call "$ctm_proxy" "BRIDGE_HUB()(address)" --rpc-url "$RPC_URL")")"
  migration_paused="$(cast call "$bridgehub" "migrationPaused()(bool)" --rpc-url "$RPC_URL")"
  bridgehub_owner="$(normalize_address "$(cast call "$bridgehub" "owner()(address)" --rpc-url "$RPC_URL")")"

  if [[ "$(cast code "$governance" --rpc-url "$RPC_URL")" == "0x" ]]; then
    echo "CTM owner $governance is not a contract; expected Governance" >&2
    exit 1
  fi

  governance_owner="$(normalize_address "$(cast call "$governance" "owner()(address)" --rpc-url "$RPC_URL")")"
  governance_min_delay="$(cast call "$governance" "minDelay()(uint256)" --rpc-url "$RPC_URL")"
  governance_min_delay="$(normalize_uint_output "$governance_min_delay")"

  if [[ "$(lowercase "$governance_owner")" != "$(lowercase "$owner_address")" ]]; then
    echo "Governance owner mismatch:" >&2
    echo "  expected signer: $owner_address" >&2
    echo "  onchain owner:   $governance_owner" >&2
    echo "  governance:      $governance" >&2
    exit 1
  fi

  if [[ "$(lowercase "$bridgehub_owner")" != "$(lowercase "$governance")" ]]; then
    echo "Bridgehub owner mismatch:" >&2
    echo "  expected governance: $governance" >&2
    echo "  bridgehub owner:     $bridgehub_owner" >&2
    exit 1
  fi

  echo "CTM proxy:                 $ctm_proxy"
  echo "Governance:                $governance"
  echo "Governance owner:          $governance_owner"
  echo "Bridgehub:                 $bridgehub"
  echo "Bridgehub owner:           $bridgehub_owner"
  echo "Migration paused:          $migration_paused"
  echo "Current protocol version:  $current_protocol_version"
  echo "New protocol version:      $NEW_PROTOCOL_VERSION"

  current_protocol_version_uint256="$(cast to-uint256 "$current_protocol_version")"
  old_protocol_version_deadline_uint256="$(cast to-uint256 "$OLD_PROTOCOL_VERSION_DEADLINE")"
  new_protocol_version_uint256="$(cast to-uint256 "$NEW_PROTOCOL_VERSION")"

  pause_migration_calldata="$(cast calldata "pauseMigration()")"
  unpause_migration_calldata="$(cast calldata "unpauseMigration()")"
  set_new_version_calldata="$(cast calldata \
    "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256)" \
    "([],$ZERO_ADDRESS,0x)" \
    "$current_protocol_version_uint256" \
    "$old_protocol_version_deadline_uint256" \
    "$new_protocol_version_uint256")"

  operation_args="([($bridgehub,0,$pause_migration_calldata),($ctm_proxy,0,$set_new_version_calldata),($bridgehub,0,$unpause_migration_calldata)],$ZERO_BYTES32,$ZERO_BYTES32)"

  print_and_run cast send \
    "$governance" \
    "scheduleTransparent(((address,uint256,bytes)[],bytes32,bytes32),uint256)" \
    "$operation_args" \
    "$governance_min_delay" \
    --rpc-url "$RPC_URL" \
    --private-key "$OWNER_PRIVATE_KEY"

  if [[ "$governance_min_delay" != "0" ]]; then
    cat <<EOF
Governance minDelay is non-zero, so the operation was only scheduled.
After the delay has elapsed, execute:

cast send "$governance" \
  "execute(((address,uint256,bytes)[],bytes32,bytes32))" \
  '$operation_args' \
  --rpc-url "$RPC_URL" \
  --private-key "\$OWNER_PRIVATE_KEY"
EOF
    exit 0
  fi

  print_and_run cast send \
    "$governance" \
    "execute(((address,uint256,bytes)[],bytes32,bytes32))" \
    "$operation_args" \
    --rpc-url "$RPC_URL" \
    --private-key "$OWNER_PRIVATE_KEY"

  updated_protocol_version="$(cast call "$ctm_proxy" "protocolVersion()(uint256)" --rpc-url "$RPC_URL")"
  updated_protocol_version="$(normalize_uint_output "$updated_protocol_version")"
  if [[ "$updated_protocol_version" != "$NEW_PROTOCOL_VERSION" ]]; then
    echo "Protocol version update failed: expected $NEW_PROTOCOL_VERSION, got $updated_protocol_version" >&2
    exit 1
  fi

  echo "Updated protocol version:  $updated_protocol_version"
  echo "Completed successfully."
}

if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  usage
  exit 0
fi

main "$@"
