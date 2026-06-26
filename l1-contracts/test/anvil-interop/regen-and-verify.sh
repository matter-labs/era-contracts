#!/bin/bash
# Regenerate a v31 upgrade calldata set against a fresh anvil fork of Sepolia,
# replay it under impersonation, and run PUVT (`ecosystem verify-upgrade`)
# against the artifacts.
#
# Works for every env. Pass the env as the first positional arg
# (default: stage):
#
#   ./regen-and-verify.sh            # stage   (port 29545)
#   ./regen-and-verify.sh testnet    # testnet (port 29547)
#   ./regen-and-verify.sh mainnet    # mainnet (port 29549)
#
# All env-specific inputs are derived from the canonical config TOMLs so this
# script never drifts from the source of truth:
#   - bridgehub  ← upgrade-envs/v0.31.0-interopB/<env>.toml  bridgehub_proxy_address
#   - ZK asset   ← upgrade-envs/permanent-values/<env>.toml  zk_token_asset_id
#   - gateway?   ← upgrade-envs/permanent-values/<env>.toml  [new_gateway] table
# Only the per-env anvil PORT is hard-mapped below (so parallel runs of
# different envs don't collide).
#
# Required env vars:
#   L1_FORK_URL                          — Sepolia RPC URL to fork
#   DEPLOYER_ADDR=<0xhex>                — canonical deployer EOA (fork-rehearsal-
#                                          only, impersonated; no key needed), OR
#   DEPLOYER_PK=<0xhex>                  — broadcast signer's private key, OR
#   DEPLOYER_PK_FILE=<path>              — file holding the same (trimmed)
#
# The deployer EOA is derived from the PK at call time; we don't read it
# from the env config (the env's `owner_address` is governance / PUH, not
# a signable EOA).
#
# Usage:
#   DEPLOYER_PK=0xabcd… L1_FORK_URL=https://… ./regen-and-verify.sh
#   DEPLOYER_PK_FILE=~/.test_pk L1_FORK_URL=https://… ./regen-and-verify.sh testnet

set -euo pipefail

if [[ -z "${L1_FORK_URL:-}" ]]; then
  echo "L1_FORK_URL is required" >&2
  exit 1
fi

# First positional arg selects the env (default: stage). Each env gets a
# distinct anvil port so stage/testnet/mainnet rehearsals can run in parallel
# without colliding (and a KEEP_ANVIL fork of one is never reused by another).
ENV="${1:-stage}"
case "$ENV" in
  stage) PORT=29545 ;;
  testnet) PORT=29547 ;;
  mainnet) PORT=29549 ;;
  *)
    echo "Unknown env '$ENV' (expected: stage | testnet | mainnet)" >&2
    exit 1
    ;;
esac
RPC="http://localhost:$PORT"
echo "Env:          $ENV (anvil port $PORT)"

# Write per-run artifacts (prepare bundles, executed.json, anvil log)
# directly to `upgrade-envs/v0.31.0-interopB/output/<env>/` so the merged
# `ecosystem.toml` produced by `upgrade-prepare-all` lands at the tracked
# path (`output/<env>/ecosystem.toml`) — the canonical artifact reviewers
# diff. `.gitignore` already excludes `output/**/*.safe.json` +
# `output/**/manifest.json`, so the per-run safe bundles + manifest stay
# untracked; only the merged TOML is committed.
L1_CONTRACTS_DIR="$(cd "$(dirname "$0")"/../.. && pwd)"
OUT="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/output/$ENV"
PERMANENT_VALUES="$L1_CONTRACTS_DIR/upgrade-envs/permanent-values/$ENV.toml"
V31_INPUT="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/$ENV.toml"
for f in "$PERMANENT_VALUES" "$V31_INPUT"; do
  [[ -f "$f" ]] || { echo "config not found: $f" >&2; exit 1; }
done

read_toml_str() {
  # $1 = file, $2 = key (top-level scalar string in TOML — `key = "0x…"`)
  python3 -c "
import re, sys
m = re.search(r'^${2}\s*=\s*[\"\']([^\"\']+)', open('${1}').read(), re.MULTILINE)
print(m.group(1) if m else '', end='')
"
}

# Bridgehub is the one address the prepare wrapper needs on the CLI; pull it
# from the env's v31 input so we don't keep a per-env copy in this script.
BRIDGEHUB="$(read_toml_str "$V31_INPUT" bridgehub_proxy_address)"
[[ -z "$BRIDGEHUB" ]] && { echo "bridgehub_proxy_address not found in $V31_INPUT" >&2; exit 1; }
echo "Bridgehub:    $BRIDGEHUB"

# Deployer EOA — derived from the broadcast signer's private key, supplied
# by the caller. We deliberately *don't* pull this from the env config: the
# env's `owner_address` is governance (PUH, a contract), not a signable EOA.
# Tying the deployer to the PK at the call site keeps env config purely
# about the ecosystem, not about who's pushing.
#
# Pass the PK one of two ways:
#   DEPLOYER_PK=0x…        — raw hex
#   DEPLOYER_PK_FILE=path  — read from file (trimmed of whitespace)
if [[ -n "${DEPLOYER_ADDR:-}" ]]; then
  # Fork-rehearsal-only override: prepare takes --deployer-address and the
  # broadcast runs --unlocked (impersonation), so no signing happens against
  # the fork. This lets a regen run with the canonical deployer EOA whose
  # private key the runner does not hold (e.g. in CI).
  DEPLOYER="$DEPLOYER_ADDR"
else
  if [[ -z "${DEPLOYER_PK:-}" ]]; then
    if [[ -n "${DEPLOYER_PK_FILE:-}" ]]; then
      if [[ ! -f "$DEPLOYER_PK_FILE" ]]; then
        echo "DEPLOYER_PK_FILE=$DEPLOYER_PK_FILE does not exist" >&2
        exit 1
      fi
      DEPLOYER_PK="$(tr -d '[:space:]' < "$DEPLOYER_PK_FILE")"
    else
      echo "Set either DEPLOYER_ADDR=<0xhex>, DEPLOYER_PK=<0xhex> or DEPLOYER_PK_FILE=<path> before running" >&2
      exit 1
    fi
  fi
  DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PK")"
fi
echo "Deployer EOA: $DEPLOYER"

ZK_ASSET_ID="$(read_toml_str "$PERMANENT_VALUES" zk_token_asset_id)"
[[ -z "$ZK_ASSET_ID" ]] && { echo "zk_token_asset_id not found in $PERMANENT_VALUES" >&2; exit 1; }
echo "ZK asset id:  $ZK_ASSET_ID"

# Does this env have a new Gateway? Gateway-enabled envs (stage, mainnet) have a
# `[new_gateway]` table in permanent-values; their ZK token is the new-GW base
# token (NTV-mintable) and bundle 5's GW priority tx burns it, so ZK funding
# MUST succeed. Gateway-less envs (testnet) omit the table; their ZK token is
# L1-native (a plain ERC20, not NTV-mintable → bridgeMint reverts) and no GW
# priority tx burns ZK, so the funding is both impossible and unnecessary.
if grep -qE '^\[new_gateway\]' "$PERMANENT_VALUES"; then
  HAS_GATEWAY=1
else
  HAS_GATEWAY=0
fi
echo "New gateway:  $([[ "$HAS_GATEWAY" == "1" ]] && echo yes || echo "no (ZK funding best-effort)")"

# Gateway RPC — PUVT uses it for read-only GW-side checks (only exercised on
# gateway-enabled envs; gateway-less envs treat [new_gateway] as absent and skip
# them, so the URL is just a reachable placeholder there). The default points
# at stage's gateway — override GW_RPC_URL for other gateway-enabled envs.
GW_RPC_URL="${GW_RPC_URL:-https://zksync-os-stage-gateway.zksync.dev}"
echo "GW RPC:       $GW_RPC_URL"
# zk-governance commit whose AllContractsHashes.json PUVT uses to verify
# PUH/Guardians bytecodes. Override via ZK_GOVERNANCE_COMMIT env var; the
# default points to the v31 governance set on upstream
# (zksync-association/zk-governance).
ZK_GOV_COMMIT="${ZK_GOVERNANCE_COMMIT:-cc7c76d}"
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
  # Preserve transactions.txt across the wipe: back it up, then restore after mkdir.
  [[ -f "$OUT/transactions.txt" ]] && _txbak=$(mktemp) && cp "$OUT/transactions.txt" "$_txbak"
  rm -rf "$OUT"
fi
mkdir -p "$OUT"
[[ -n "${_txbak:-}" ]] && mv "$_txbak" "$OUT/transactions.txt"

# If an anvil is already serving on $PORT (left running from a previous
# `KEEP_ANVIL=1` invocation), reuse it. The prior broadcast's state lives on
# that anvil — exactly what verify-upgrade Phase 5 (runtime hash) needs.
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "=== Step 0: reusing anvil on $RPC ==="
else
  echo "=== Step 0: anvil fork on port $PORT ==="
  # Optional FORK_BLOCK pin. Needed when the live chain is mid-upgrade: forking the tip would
  # inherit an already-applied stage (e.g. a started GovernanceUpgradeTimer), making the prepare's
  # gov-stage replay revert. Pin to a pre-upgrade block to fork a clean pre-stage state.
  anvil_args=(
    --port "$PORT"
    --auto-impersonate
    --disable-block-gas-limit
    --gas-price 1000000000
    --fork-url "$L1_FORK_URL"
  )
  if [[ -n "${FORK_BLOCK:-}" ]]; then
    echo "    pinning fork to block $FORK_BLOCK"
    anvil_args+=(--fork-block-number "$FORK_BLOCK")
  fi
  anvil "${anvil_args[@]}" >"$OUT/anvil.log" 2>&1 &
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
    --env "$ENV" \
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
if [[ "$SKIP_BROADCAST" == "1" && -f "$OUT/fork-rehearsal/executed.json" ]]; then
  echo "=== Steps 2-3: SKIPPED (SKIP_BROADCAST=1, reusing $OUT/fork-rehearsal/executed.json) ==="
  echo "=== Step 4: verify-upgrade (PUVT) ==="
  # Same committed-real + fork-rehearsal combined log as the full path below.
  COMBINED_TXLOG="$OUT/fork-rehearsal/transactions.combined.txt"
  : > "$COMBINED_TXLOG"
  [[ -f "$OUT/transactions.txt" ]] && cat "$OUT/transactions.txt" >> "$COMBINED_TXLOG"
  [[ -f "$OUT/fork-rehearsal/transactions.txt" ]] && cat "$OUT/fork-rehearsal/transactions.txt" >> "$COMBINED_TXLOG"
  "$PROTOCOL_OPS" ecosystem verify-upgrade \
    --env "$ENV" \
    --ecosystem-toml "$OUT/ecosystem.toml" \
    --l1-rpc-url "$RPC" \
    --gw-rpc-url "$GW_RPC_URL" \
    --transactions-log "$COMBINED_TXLOG" \
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
  if [[ "$HAS_GATEWAY" == "1" ]]; then
    # Gateway-enabled env: ZK is the NTV-mintable new-GW base token and bundle 5's
    # GW priority tx burns it — funding must succeed.
    echo "  bridgeMint($TARGET, $FUND_AMOUNT)"
    cast send --from "$NTV" --unlocked "$ZK_TOKEN" \
      "bridgeMint(address,uint256)" "$TARGET" "$FUND_AMOUNT" \
      --rpc-url "$RPC" >/dev/null
  else
    # Gateway-less env: the ZK token is L1-native (a plain ERC20, not
    # NTV-mintable, so bridgeMint reverts Unauthorized(NTV)) and unnecessary —
    # no GW priority tx burns ZK. Tolerate the revert; the ETH gas funding
    # above is all the fork replay needs.
    echo "  bridgeMint($TARGET, $FUND_AMOUNT) [best-effort]"
    cast send --from "$NTV" --unlocked "$ZK_TOKEN" \
      "bridgeMint(address,uint256)" "$TARGET" "$FUND_AMOUNT" \
      --rpc-url "$RPC" >/dev/null 2>&1 || true
  fi
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
# The committed `transactions.txt` holds *real-network* deployment hashes only
# (they resolve on any Sepolia fork). This fork rehearsal mines its own hashes,
# which exist solely on this local fork instance — so they go to an EPHEMERAL,
# git-ignored dir and are NEVER merged into the committed log. `protocol_ops`
# writes the hash log next to `--out`, so pointing `--out` at `fork-rehearsal/`
# keeps the fork hashes (`fork-rehearsal/transactions.txt`) cleanly separated.
# PUVT (Step 4) then reads the committed real log + this run's fork log.
REAL_TXLOG="$OUT/transactions.txt"
FORK_DIR="$OUT/fork-rehearsal"
FORK_TXLOG="$FORK_DIR/transactions.txt"
rm -rf "$FORK_DIR"
mkdir -p "$FORK_DIR"
# Pin the base fee to 1 gwei so the EIP-1559 escalation doesn't cause
# MsgValueTooLow on priority deposit txs whose mintValue was computed
# at prepare-time with a lower gas price.
cast rpc anvil_setNextBlockBaseFeePerGas 0x3B9ACA00 --rpc-url "$RPC" >/dev/null
"$PROTOCOL_OPS" ecosystem upgrade-broadcast \
  --manifest "$OUT/prepare/manifest.json" \
  --l1-rpc-url "$RPC" \
  --unlocked \
  --out "$FORK_DIR/executed.json"

echo "=== Step 4: verify-upgrade (PUVT) ==="
# Feed PUVT the committed real-network log followed by this run's fork log.
COMBINED_TXLOG="$FORK_DIR/transactions.combined.txt"
: > "$COMBINED_TXLOG"
[[ -f "$REAL_TXLOG" ]] && cat "$REAL_TXLOG" >> "$COMBINED_TXLOG"
[[ -f "$FORK_TXLOG" ]] && cat "$FORK_TXLOG" >> "$COMBINED_TXLOG"
"$PROTOCOL_OPS" ecosystem verify-upgrade \
  --env "$ENV" \
  --ecosystem-toml "$OUT/ecosystem.toml" \
  --l1-rpc-url "$RPC" \
  --gw-rpc-url "$GW_RPC_URL" \
  --transactions-log "$COMBINED_TXLOG" \
  --zk-governance-commit "$ZK_GOV_COMMIT"

echo "=== Done ==="
