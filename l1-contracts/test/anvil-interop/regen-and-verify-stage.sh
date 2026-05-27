#!/bin/bash
# Regenerate the v31 stage upgrade calldata against a fresh anvil fork of
# Sepolia, replay it under impersonation, and run PUVT (`ecosystem
# verify-upgrade`) against the artifacts.
#
# Required env vars:
#   L1_FORK_URL                          — Sepolia RPC URL to fork
#   DEPLOYER_PK=<0xhex>                  — broadcast signer's private key, OR
#   DEPLOYER_PK_FILE=<path>              — file holding the same (trimmed)
#
# The deployer EOA is derived from the PK at call time; we don't read it
# from the env config (the env's `owner_address` is governance / PUH, not
# a signable EOA).
#
# Usage:
#   DEPLOYER_PK=0xabcd… L1_FORK_URL=https://… ./regen-and-verify-stage.sh
#   DEPLOYER_PK_FILE=~/.test_pk L1_FORK_URL=https://… ./regen-and-verify-stage.sh

set -euo pipefail

if [[ -z "${L1_FORK_URL:-}" ]]; then
  echo "L1_FORK_URL is required" >&2
  exit 1
fi

PORT=29545
RPC="http://localhost:$PORT"
# Write per-run artifacts (prepare bundles, executed.json, anvil log)
# directly to `upgrade-envs/v0.31.0-interopB/output/<env>/` so the merged
# `ecosystem.toml` produced by `upgrade-prepare-all` lands at the tracked
# path (`output/stage/ecosystem.toml`) — the canonical artifact reviewers
# diff. `.gitignore` already excludes `output/**/*.safe.json` +
# `output/**/manifest.json`, so the per-run safe bundles + manifest stay
# untracked; only the merged TOML is committed.
L1_CONTRACTS_DIR="$(cd "$(dirname "$0")"/../.. && pwd)"
OUT="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/output/stage"
BRIDGEHUB="0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE"
# Deployer EOA — derived from the broadcast signer's private key, supplied
# by the caller. We deliberately *don't* pull this from the env config: the
# env's `owner_address` is governance (PUH, a contract), not a signable EOA.
# Tying the deployer to the PK at the call site keeps env config purely
# about the ecosystem, not about who's pushing.
#
# Pass the PK one of two ways:
#   DEPLOYER_PK=0x…        — raw hex
#   DEPLOYER_PK_FILE=path  — read from file (trimmed of whitespace)
if [[ -z "${DEPLOYER_PK:-}" ]]; then
  if [[ -n "${DEPLOYER_PK_FILE:-}" ]]; then
    if [[ ! -f "$DEPLOYER_PK_FILE" ]]; then
      echo "DEPLOYER_PK_FILE=$DEPLOYER_PK_FILE does not exist" >&2
      exit 1
    fi
    DEPLOYER_PK="$(tr -d '[:space:]' < "$DEPLOYER_PK_FILE")"
  else
    echo "Set either DEPLOYER_PK=<0xhex> or DEPLOYER_PK_FILE=<path> before running" >&2
    exit 1
  fi
fi
DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PK")"
echo "Deployer EOA: $DEPLOYER"
# Pull env-specific values from the canonical config TOMLs so this script
# doesn't drift from the source of truth when stage/mainnet/testnet update.
PERMANENT_VALUES="$L1_CONTRACTS_DIR/upgrade-envs/permanent-values/stage.toml"
read_toml_str() {
  # $1 = file, $2 = key (top-level scalar string in TOML — `key = "0x…"`)
  python3 -c "
import re, sys
m = re.search(r'^${2}\s*=\s*[\"\']([^\"\']+)', open('${1}').read(), re.MULTILINE)
print(m.group(1) if m else '', end='')
"
}
ZK_ASSET_ID="$(read_toml_str "$PERMANENT_VALUES" zk_token_asset_id)"
[[ -z "$ZK_ASSET_ID" ]] && { echo "zk_token_asset_id not found in $PERMANENT_VALUES" >&2; exit 1; }
echo "ZK asset id:  $ZK_ASSET_ID"
# Gateway RPC — PUVT uses it for read-only GW-side checks.
GW_RPC_URL="${GW_RPC_URL:-https://zksync-os-stage-gateway.zksync.dev}"
echo "GW RPC:       $GW_RPC_URL"
# zk-governance commit for PUH/Guardians bytecode verification.
# zk-governance commit whose AllContractsHashes.json PUVT uses to verify
# PUH/Guardians bytecodes. Override via ZK_GOVERNANCE_COMMIT env var; the
# default points to the latest kl/v31-puh-guardians-redeploy on upstream
# (zksync-association/zk-governance) which carries the regenerated hashes.
ZK_GOV_COMMIT="${ZK_GOVERNANCE_COMMIT:-7c5e27b}"
echo "zk-gov commit: $ZK_GOV_COMMIT"
# 1e30 wei
FUND_AMOUNT="1000000000000000000000000000000"

# Locate the protocol_ops binary. Prefer the local debug build (devs iterate
# on this), then the release build, then anything on PATH (Docker image puts
# it on PATH via /contracts/protocol-ops/).
_PO_DIR="$(cd "$(dirname "$0")"/../../../protocol-ops && pwd)"
if [[ -x "$_PO_DIR/target/debug/protocol_ops" ]]; then
  PROTOCOL_OPS="$_PO_DIR/target/debug/protocol_ops"
elif [[ -x "$_PO_DIR/target/release/protocol_ops" ]]; then
  PROTOCOL_OPS="$_PO_DIR/target/release/protocol_ops"
elif [[ -x "$_PO_DIR/protocol_ops" ]]; then
  PROTOCOL_OPS="$_PO_DIR/protocol_ops"
elif command -v protocol_ops >/dev/null 2>&1; then
  PROTOCOL_OPS="$(command -v protocol_ops)"
else
  echo "protocol_ops binary not found — build it with 'cd protocol-ops && cargo build'" >&2
  exit 1
fi
echo "Using protocol_ops at: $PROTOCOL_OPS"

# Set KEEP_ANVIL=1 to leave the fork anvil running on $PORT after the script
# exits. Use together with SKIP_PREPARE=1 + SKIP_BROADCAST=1 to iterate on
# verify-upgrade (seconds per run) without rebroadcasting (minutes per run).
KEEP_ANVIL="${KEEP_ANVIL:-0}"
cleanup() {
  if [[ "$KEEP_ANVIL" == "1" ]]; then
    echo "Leaving anvil (pid ${ANVIL_PID:-?}) running on $RPC (KEEP_ANVIL=1)"
    return
  fi
  if [[ -n "${ANVIL_PID:-}" ]]; then
    echo "Stopping anvil (pid $ANVIL_PID)..."
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Set SKIP_PREPARE=1 to reuse the existing $OUT/prepare/ output. The bundles
# are deterministic, so re-running with the same env config produces identical
# manifests — letting us iterate fast on the broadcast / verify path.
SKIP_PREPARE="${SKIP_PREPARE:-0}"
if [[ "$SKIP_PREPARE" != "1" ]]; then
  rm -rf "$OUT"
fi
mkdir -p "$OUT"

# If an anvil is already serving on $PORT (left running from a previous
# `KEEP_ANVIL=1` invocation), reuse it. The prior broadcast's state lives on
# that anvil — exactly what verify-upgrade Phase 5 (runtime hash) needs.
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "=== Step 0: reusing anvil on $RPC ==="
else
  echo "=== Step 0: anvil fork on port $PORT ==="
  anvil \
    --port $PORT \
    --auto-impersonate \
    --disable-block-gas-limit \
    --gas-price 1000000000 \
    --fork-url "$L1_FORK_URL" \
    >"$OUT/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  cast chain-id --rpc-url "$RPC" >/dev/null || { echo "anvil failed to start"; exit 1; }
fi

if [[ "$SKIP_PREPARE" == "1" && -f "$OUT/prepare/manifest.json" ]]; then
  echo "=== Step 1: SKIPPED (SKIP_PREPARE=1, reusing existing $OUT/prepare) ==="
else
  echo "=== Step 1: upgrade-prepare-all (this takes ~12 min) ==="
  "$PROTOCOL_OPS" ecosystem upgrade-prepare-all \
    --env stage \
    --bridgehub "$BRIDGEHUB" \
    --l1-rpc-url "$RPC" \
    --deployer-address "$DEPLOYER" \
    --out "$OUT/prepare" \
    --additional-args=--memory-limit=536870912
fi

# Set SKIP_BROADCAST=1 to skip Step 2 (funding) + Step 3 (bundle replay) and
# go straight to verify-upgrade against an already-broadcast anvil state.
# Useful for iterating on PUVT without paying the broadcast cost every time.
SKIP_BROADCAST="${SKIP_BROADCAST:-0}"
if [[ "$SKIP_BROADCAST" == "1" && -f "$OUT/executed.json" ]]; then
  echo "=== Steps 2-3: SKIPPED (SKIP_BROADCAST=1, reusing $OUT/executed.json) ==="
  echo "=== Step 4: verify-upgrade (PUVT) ==="
  "$PROTOCOL_OPS" ecosystem verify-upgrade \
    --env stage \
    --ecosystem-toml "$OUT/ecosystem.toml" \
    --l1-rpc-url "$RPC" \
    --gw-rpc-url "$GW_RPC_URL" \
    --zk-governance-commit "$ZK_GOV_COMMIT"
  echo "=== Done ==="
  exit 0
fi

echo "=== Step 2: resolve NTV + ZK token, fund every bundle target ==="
AR=$(cast call "$BRIDGEHUB" "assetRouter()(address)" --rpc-url "$RPC")
NTV=$(cast call "$AR" "nativeTokenVault()(address)" --rpc-url "$RPC")
ZK_TOKEN=$(cast call "$NTV" "tokenAddress(bytes32)(address)" "$ZK_ASSET_ID" --rpc-url "$RPC")
echo "AR=$AR"
echo "NTV=$NTV"
echo "ZK_TOKEN=$ZK_TOKEN"
cast rpc anvil_setBalance "$NTV" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
# Pull every distinct bundle.target from the manifest. Fund each with both
# ETH (gas) and ZK (base-token burn for any GW priority tx). On the deployer-
# EOA-with-PUH-as-owner split we get the deployer EOA, the security council
# EOA, AND PUH itself in there — PUH lands in the list because it owns a
# CTM/ProxyAdmin and the wrap script broadcasts the corresponding accept-
# ownership / transferOwnership txs from PUH.
TARGETS=$(jq -r '.bundles[].target' "$OUT/prepare/manifest.json" | sort -u)
echo "Bundle targets:"
echo "$TARGETS" | sed 's/^/  /'
for TARGET in $TARGETS; do
  cast rpc anvil_setBalance "$TARGET" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
  echo "  bridgeMint($TARGET, $FUND_AMOUNT)"
  cast send --from "$NTV" --unlocked "$ZK_TOKEN" \
    "bridgeMint(address,uint256)" "$TARGET" "$FUND_AMOUNT" \
    --rpc-url "$RPC" >/dev/null
done

# Register the ZK token assetId in L1AssetTracker so bundle 5's GW priority
# deposits (which burn ZK as the new-GW base token) pass the
# `_requireRegistered` check on `handleChainBalanceIncreaseOnL1`. In production
# this registration lands as stage-2 call 6 (`registerLegacyToken`), but Step 3
# replays the prepare bundles BEFORE governance, so we prime it here directly.
# `registerLegacyToken` is public — anyone can call it.
ASSET_TRACKER=$(awk -F'"' '/^asset_tracker_proxy_addr[ \t]*=/{print $2; exit}' "$OUT/ecosystem.toml")
if [ -n "$ASSET_TRACKER" ]; then
  echo "  registerLegacyToken($ZK_ASSET_ID) on $ASSET_TRACKER"
  cast send "$ASSET_TRACKER" "registerLegacyToken(bytes32)" "$ZK_ASSET_ID" \
    --from "$DEPLOYER" --unlocked --rpc-url "$RPC" >/dev/null || true
else
  echo "  WARNING: asset_tracker_proxy_addr not found in $OUT/ecosystem.toml — skipping registerLegacyToken"
fi

echo "=== Step 3: upgrade-broadcast --unlocked --out ==="
# transactions.txt is append-only: real deployment tx hashes accumulate
# across regens. Back up any existing hashes before the broadcast step
# (which writes anvil-fork hashes), then prepend them afterward so the
# file always starts with the real hashes.
TXLOG="$OUT/transactions.txt"
TXLOG_BAK="$OUT/.transactions.txt.bak"
if [[ -s "$TXLOG" ]]; then
  cp "$TXLOG" "$TXLOG_BAK"
  : > "$TXLOG"
fi
# Pin the base fee to 1 gwei so the EIP-1559 escalation doesn't cause
# MsgValueTooLow on priority deposit txs whose mintValue was computed
# at prepare-time with a lower gas price.
cast rpc anvil_setNextBlockBaseFeePerGas 0x3B9ACA00 --rpc-url "$RPC" >/dev/null
"$PROTOCOL_OPS" ecosystem upgrade-broadcast \
  --manifest "$OUT/prepare/manifest.json" \
  --l1-rpc-url "$RPC" \
  --unlocked \
  --out "$OUT/executed.json"
# Restore backed-up hashes before the fresh anvil ones.
if [[ -f "$TXLOG_BAK" ]]; then
  cat "$TXLOG" >> "$TXLOG_BAK"
  mv "$TXLOG_BAK" "$TXLOG"
fi

echo "=== Step 4: verify-upgrade (PUVT) ==="
"$PROTOCOL_OPS" ecosystem verify-upgrade \
  --env stage \
  --ecosystem-toml "$OUT/ecosystem.toml" \
  --l1-rpc-url "$RPC" \
  --gw-rpc-url "$GW_RPC_URL" \
  --zk-governance-commit "$ZK_GOV_COMMIT"

echo "=== Done ==="
