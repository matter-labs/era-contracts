#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
PROTOCOL_VERSION_SLOT="157"
TARGET_PROTOCOL_VERSION="124554051585"
TEMP_IMPLEMENTATION_ARTIFACT="out/TemporaryCtmProtocolVersionSetter.sol/TemporaryCtmProtocolVersionSetter.json"
ZERO_BYTES32="0x0000000000000000000000000000000000000000000000000000000000000000"

usage() {
  cat <<'EOF'
Usage:
  scripts/set_ctm_protocol_version_via_temp_impl.sh

Required env vars:
  CTM_PROXY                 Address of the CTM proxy.
  RPC_URL                   RPC URL for the target chain.
  OWNER_PRIVATE_KEY         Private key of the EOA signer.

Optional env vars:
  PROXY_ADMIN               Override ProxyAdmin address. Defaults to the proxy admin slot value.
  TEMP_IMPLEMENTATION       Reuse an already deployed temporary implementation.

What it does:
  1. Reads the current CTM implementation from the proxy.
  2. Reads the live `BRIDGE_HUB()` from the CTM proxy.
  3. Deploys a temporary CTM-derived implementation if needed.
  4. If ProxyAdmin is owned by Governance, schedules and executes a single governance
     operation containing:
       - `ProxyAdmin.upgradeAndCall(proxy, tempImpl, setProtocolVersion())`
       - `ProxyAdmin.upgrade(proxy, originalImpl)`
     If ProxyAdmin is owned directly by the signer EOA, it sends those two calls directly.
  5. Verifies that slot 157 now contains `124554051585` and that the original
     implementation was restored.

Notes:
  - The script does not restore the old protocolVersion value. It restores only
    the original implementation address.
  - The provided private key must either directly own the CTM ProxyAdmin, or own
    the Governance contract that owns the CTM ProxyAdmin.
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

print_command() {
  printf '+' >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
}

normalize_address() {
  cast to-check-sum-address "$1"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

slot_to_address() {
  local value="$1"
  if [[ ! "$value" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "Invalid storage value: $value" >&2
    exit 1
  fi
  normalize_address "0x${value:26}"
}

deploy_temp_implementation() {
  local bridgehub="$1"
  local creation_code constructor_args deploy_data send_output deployed_to

  if [[ ! -f "$TEMP_IMPLEMENTATION_ARTIFACT" ]]; then
    echo "Missing artifact: $TEMP_IMPLEMENTATION_ARTIFACT" >&2
    echo "Compile the temporary implementation first, then rerun the script." >&2
    exit 1
  fi

  creation_code="$(jq -r '.bytecode.object // .bytecode' "$TEMP_IMPLEMENTATION_ARTIFACT")"
  if [[ -z "$creation_code" || "$creation_code" == "null" ]]; then
    echo "Could not extract creation bytecode from $TEMP_IMPLEMENTATION_ARTIFACT" >&2
    exit 1
  fi

  constructor_args="$(cast abi-encode "constructor(address)" "$bridgehub")"
  deploy_data="${creation_code}${constructor_args#0x}"

  print_command cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$OWNER_PRIVATE_KEY" \
    --json \
    --create "$deploy_data"

  if ! send_output="$(
    cast send \
      --rpc-url "$RPC_URL" \
      --private-key "$OWNER_PRIVATE_KEY" \
      --json \
      --create "$deploy_data" 2>&1
  )"; then
    printf '%s\n' "$send_output" >&2
    exit 1
  fi

  printf '%s\n' "$send_output" >&2

  deployed_to="$(
    printf '%s' "$send_output" |
      tr -d '\n\r' |
      sed -nE 's/.*"contractAddress"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]{40})".*/\1/p'
  )"

  if [[ -z "$deployed_to" ]]; then
    echo "Could not extract contractAddress from cast send output" >&2
    exit 1
  fi

  normalize_address "$deployed_to"
}

main() {
  require_env CTM_PROXY
  require_env RPC_URL
  require_env OWNER_PRIVATE_KEY

  local ctm_proxy owner_address proxy_admin implementation proxy_admin_owner temp_implementation bridgehub
  local set_protocol_calldata upgrade_and_call_calldata restore_calldata
  local before_protocol after_protocol restored_implementation
  local proxy_admin_owner_code governance_owner governance_min_delay operation_args

  cd "$ROOT_DIR"

  ctm_proxy="$(normalize_address "$CTM_PROXY")"
  owner_address="$(cast wallet address --private-key "$OWNER_PRIVATE_KEY")"

  if [[ -n "${PROXY_ADMIN:-}" ]]; then
    proxy_admin="$(normalize_address "$PROXY_ADMIN")"
  else
    proxy_admin="$(slot_to_address "$(cast storage "$ctm_proxy" "$ADMIN_SLOT" --rpc-url "$RPC_URL")")"
  fi

  implementation="$(slot_to_address "$(cast storage "$ctm_proxy" "$IMPLEMENTATION_SLOT" --rpc-url "$RPC_URL")")"
  bridgehub="$(normalize_address "$(cast call "$ctm_proxy" "BRIDGE_HUB()(address)" --rpc-url "$RPC_URL")")"
  proxy_admin_owner="$(normalize_address "$(cast call "$proxy_admin" "owner()(address)" --rpc-url "$RPC_URL")")"
  before_protocol="$(cast storage "$ctm_proxy" "$PROTOCOL_VERSION_SLOT" --rpc-url "$RPC_URL")"
  before_protocol="$(cast --to-dec "$before_protocol")"
  proxy_admin_owner_code="$(cast code "$proxy_admin_owner" --rpc-url "$RPC_URL")"

  echo "CTM proxy:                 $ctm_proxy"
  echo "ProxyAdmin:                $proxy_admin"
  echo "ProxyAdmin owner:          $proxy_admin_owner"
  echo "Bridgehub:                 $bridgehub"
  echo "Original implementation:   $implementation"
  echo "Protocol version before:   $before_protocol"

  if [[ -n "${TEMP_IMPLEMENTATION:-}" ]]; then
    temp_implementation="$(normalize_address "$TEMP_IMPLEMENTATION")"
  else
    temp_implementation="$(deploy_temp_implementation "$bridgehub")"
  fi

  echo "Temporary implementation:  $temp_implementation"

  set_protocol_calldata="$(cast calldata "setProtocolVersion()")"
  upgrade_and_call_calldata="$(cast calldata \
    "upgradeAndCall(address,address,bytes)" \
    "$ctm_proxy" \
    "$temp_implementation" \
    "$set_protocol_calldata")"
  restore_calldata="$(cast calldata \
    "upgrade(address,address)" \
    "$ctm_proxy" \
    "$implementation")"

  if [[ "$proxy_admin_owner_code" != "0x" ]]; then
    governance_owner="$(normalize_address "$(cast call "$proxy_admin_owner" "owner()(address)" --rpc-url "$RPC_URL")")"
    governance_min_delay="$(cast call "$proxy_admin_owner" "minDelay()(uint256)" --rpc-url "$RPC_URL")"

    if [[ "$(lowercase "$governance_owner")" != "$(lowercase "$owner_address")" ]]; then
      echo "Governance owner mismatch:" >&2
      echo "  expected signer:  $owner_address" >&2
      echo "  onchain owner:    $governance_owner" >&2
      echo "  governance:       $proxy_admin_owner" >&2
      exit 1
    fi

    operation_args="([($proxy_admin,0,$upgrade_and_call_calldata),($proxy_admin,0,$restore_calldata)],$ZERO_BYTES32,$ZERO_BYTES32)"

    echo "Governance owner:          $governance_owner"
    echo "Governance minDelay:       $governance_min_delay"

    print_and_run cast send \
      "$proxy_admin_owner" \
      "scheduleTransparent(((address,uint256,bytes)[],bytes32,bytes32),uint256)" \
      "$operation_args" \
      "$governance_min_delay" \
      --rpc-url "$RPC_URL" \
      --private-key "$OWNER_PRIVATE_KEY"

    if [[ "$governance_min_delay" != "0" ]]; then
      cat <<EOF
Governance minDelay is non-zero, so the operation was only scheduled.
After the delay has elapsed, execute:

cast send "$proxy_admin_owner" \
  "execute(((address,uint256,bytes)[],bytes32,bytes32))" \
  '$operation_args' \
  --rpc-url "$RPC_URL" \
  --private-key "\$OWNER_PRIVATE_KEY"
EOF
      exit 0
    fi

    print_and_run cast send \
      "$proxy_admin_owner" \
      "execute(((address,uint256,bytes)[],bytes32,bytes32))" \
      "$operation_args" \
      --rpc-url "$RPC_URL" \
      --private-key "$OWNER_PRIVATE_KEY"
  else
    if [[ "$(lowercase "$proxy_admin_owner")" != "$(lowercase "$owner_address")" ]]; then
      echo "ProxyAdmin owner mismatch:" >&2
      echo "  expected signer: $owner_address" >&2
      echo "  onchain owner:   $proxy_admin_owner" >&2
      exit 1
    fi

    print_and_run cast send \
      "$proxy_admin" \
      "upgradeAndCall(address,address,bytes)" \
      "$ctm_proxy" \
      "$temp_implementation" \
      "$set_protocol_calldata" \
      --rpc-url "$RPC_URL" \
      --private-key "$OWNER_PRIVATE_KEY"

    print_and_run cast send \
      "$proxy_admin" \
      "upgrade(address,address)" \
      "$ctm_proxy" \
      "$implementation" \
      --rpc-url "$RPC_URL" \
      --private-key "$OWNER_PRIVATE_KEY"
  fi

  restored_implementation="$(slot_to_address "$(cast storage "$ctm_proxy" "$IMPLEMENTATION_SLOT" --rpc-url "$RPC_URL")")"
  after_protocol="$(cast storage "$ctm_proxy" "$PROTOCOL_VERSION_SLOT" --rpc-url "$RPC_URL")"
  after_protocol="$(cast --to-dec "$after_protocol")"
  if [[ "$after_protocol" != "$TARGET_PROTOCOL_VERSION" ]]; then
    echo "Protocol version write failed: expected $TARGET_PROTOCOL_VERSION, got $after_protocol" >&2
    exit 1
  fi
  if [[ "$(lowercase "$restored_implementation")" != "$(lowercase "$implementation")" ]]; then
    echo "Implementation restore failed: expected $implementation, got $restored_implementation" >&2
    exit 1
  fi

  echo "Protocol version after:    $after_protocol"
  echo "Restored implementation:   $restored_implementation"
  echo "Completed successfully."
}

if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  usage
  exit 0
fi

main "$@"
