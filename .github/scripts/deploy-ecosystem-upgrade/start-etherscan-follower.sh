#!/usr/bin/env bash
# The "Start Etherscan verification alongside the broadcast" step of deploy-ecosystem-upgrade.yaml.
set -euo pipefail
VERIFY_DIR="$RUNNER_TEMP/etherscan-verify"
mkdir -p "$VERIFY_DIR"
# Mounted at the same path in the image, for this verifier and the broadcast's --halt-when.
export EXTRA_MOUNTS="$EXTRA_MOUNTS $VERIFY_DIR:$VERIFY_DIR"
# A follower that cannot run must stop the deploy before the broadcast, not after it.
if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
  echo "::error::ETHERSCAN_API_KEY is required with run_verify"; exit 1
fi
forge_script=()
if [ "${UPGRADE_KIND:-}" = "forge-script" ]; then forge_script=(--forge-script); fi
(
  set +e
  bash protocol-ops.sh --tag "$BUNDLE_IMAGE" ecosystem etherscan-verify \
    --bundle "$DEPLOY_BUNDLE_DIR" \
    --l1-rpc-url "$L1_RPC_URL" \
    --stop-when "$VERIFY_DIR/broadcast-done" \
    "${forge_script[@]}" > "$VERIFY_DIR/log" 2>&1
  status=$?
  # Once the verifier is gone, the broadcast stops before its next transaction (--halt-when).
  if [ "$status" != 0 ]; then touch "$VERIFY_DIR/failed"; fi
  echo "$status" > "$VERIFY_DIR/status.tmp"
  mv "$VERIFY_DIR/status.tmp" "$VERIFY_DIR/status"
) &
sleep 5
if [ -f "$VERIFY_DIR/status" ] && [ "$(cat "$VERIFY_DIR/status")" != 0 ]; then
  cat "$VERIFY_DIR/log"
  echo "::error::The Etherscan verifier failed before the broadcast"; exit 1
fi
{
  echo "ETHERSCAN_VERIFY_DIR=$VERIFY_DIR"
  echo "EXTRA_MOUNTS=$EXTRA_MOUNTS"
} >> "$GITHUB_ENV"
