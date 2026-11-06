#!/usr/bin/env bash
# The "Start Etherscan verification alongside the broadcast" step of deploy-ecosystem-upgrade.yaml.
set -euo pipefail
VERIFY_DIR="$RUNNER_TEMP/etherscan-verify"
mkdir -p "$VERIFY_DIR"
# A follower that cannot run must stop the deploy before the broadcast, not after it.
if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
  echo "::error::ETHERSCAN_API_KEY is required with run_verify"; exit 1
fi
forge_script=()
if [ "${UPGRADE_KIND:-}" = "forge-script" ]; then forge_script=(--forge-script); fi
(
  set +e
  ./protocol-ops/target/release/protocol_ops ecosystem etherscan-verify \
    --bundle "$DEPLOY_BUNDLE_DIR" \
    --l1-rpc-url "$L1_RPC_URL" \
    --stop-when "$VERIFY_DIR/broadcast-done" \
    "${forge_script[@]}" > "$VERIFY_DIR/log" 2>&1
  echo $? > "$VERIFY_DIR/status.tmp"
  mv "$VERIFY_DIR/status.tmp" "$VERIFY_DIR/status"
) &
sleep 5
if [ -f "$VERIFY_DIR/status" ] && [ "$(cat "$VERIFY_DIR/status")" != 0 ]; then
  cat "$VERIFY_DIR/log"
  echo "::error::The Etherscan verifier failed before the broadcast"; exit 1
fi
echo "ETHERSCAN_VERIFY_DIR=$VERIFY_DIR" >> "$GITHUB_ENV"
