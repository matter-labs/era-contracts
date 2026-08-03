#!/bin/bash
# Regenerate a v31 upgrade calldata set against a fresh anvil fork of Sepolia,
# replay it under impersonation, and run PUVT (`ecosystem verify-upgrade`)
# against the artifacts.
#
# Also packs `output/<env>/deploy-bundle/` (see `pack-deploy-bundle.sh`): the
# deployer calls plus the provenance needed to broadcast this run's bytecode
# elsewhere and re-verify it. That bundle — not a re-run of this script — is what
# transfers to another machine, because the compiled bytecode (and with it every
# CREATE2 address) is specific to the build environment.
#
# Works for every env. Pass the env as the first positional arg
# (default: stage):
#
#   ./regen-and-verify.sh            # stage   (port 29545)
#   ./regen-and-verify.sh testnet    # testnet (port 29547)
#   ./regen-and-verify.sh mainnet    # mainnet (port 29549)
#   ./regen-and-verify.sh battlechain # battlechain (port 29551)
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

# Shared helpers (TOML reads, protocol_ops lookup, anvil fork, bundle funding),
# also used by `replay-bundle-and-verify.sh`.
# shellcheck source=./upgrade-bundle-lib.sh
source "$(dirname "$0")/upgrade-bundle-lib.sh"

if [[ -z "${L1_FORK_URL:-}" ]]; then
  echo "L1_FORK_URL is required" >&2
  exit 1
fi

# First positional arg selects the env (default: stage). Each env gets a
# distinct anvil port (see `env_anvil_port`) so stage/testnet/mainnet rehearsals
# can run in parallel without colliding (and a KEEP_ANVIL fork of one is never
# reused by another).
ENV="${1:-stage}"
PORT="$(env_anvil_port "$ENV")"
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

# Does this env have a new Gateway? (see `env_has_gateway` for what that implies
# for the ZK funding below.)
HAS_GATEWAY="$(env_has_gateway "$PERMANENT_VALUES")"
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

_PO_DIR="$(cd "$(dirname "$0")"/../../../protocol-ops && pwd)"
PROTOCOL_OPS="$(locate_protocol_ops "$_PO_DIR")"
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
  start_anvil_fork "$PORT" "$L1_FORK_URL" "${FORK_BLOCK:-}" "$OUT/anvil.log"
fi
# The block the bundles below are computed against. Recorded in the deploy
# bundle's metadata so a later replay can fork the very same state.
FORKED_AT_BLOCK="$(cast block-number --rpc-url "$RPC")"
echo "Forked at block: $FORKED_AT_BLOCK"

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

# Pack the transferable deploy bundle right after the prepare — it only needs
# the prepare output, so the handoff artifact exists even if the replay or PUVT
# below fails. This is what somebody else broadcasts and re-verifies: the bundle
# carries the compiled init code, which a rebuild on another machine would not
# reproduce byte-for-byte (path-dependent solc metadata → different CREATE2
# addresses). See pack-deploy-bundle.sh.
echo "=== Step 1b: pack the deploy bundle ==="
DEPLOYER_ADDR="$DEPLOYER" \
FORKED_AT_BLOCK="$FORKED_AT_BLOCK" \
ZK_GOVERNANCE_COMMIT="$ZK_GOV_COMMIT" \
  "$(dirname "$0")/pack-deploy-bundle.sh" "$ENV"

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
  run_verify_upgrade "$PROTOCOL_OPS" \
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
fund_bundle_targets "$RPC" "$BRIDGEHUB" "$ZK_ASSET_ID" "$HAS_GATEWAY" \
  "$OUT/prepare/manifest.json" "$OUT/ecosystem.toml" "$DEPLOYER"

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
run_verify_upgrade "$PROTOCOL_OPS" \
  --env "$ENV" \
  --ecosystem-toml "$OUT/ecosystem.toml" \
  --l1-rpc-url "$RPC" \
  --gw-rpc-url "$GW_RPC_URL" \
  --transactions-log "$COMBINED_TXLOG" \
  --zk-governance-commit "$ZK_GOV_COMMIT"

echo "=== Done ==="
