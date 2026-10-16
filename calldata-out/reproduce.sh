#!/usr/bin/env bash
#
# Reproduce the chain-301 (Era / testnet-Sepolia) v31 upgrade calldata that
# ALSO atomically sets the DA validator pair, in a single ChainAdmin.multicall.
#
# Idempotent: safe to re-run. Each run rebuilds the protocol-ops binary (no-op
# if already built) and regenerates the Safe bundle into calldata-out/chain-301/.
#
# Requires: a vanilla Foundry toolchain (forge/cast/anvil >= 1.5.x) on PATH, a
# Rust toolchain, and the env var $TENDERLY_SEPOLIA (L1 Sepolia RPC).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/calldata-out/chain-301"

# --- Era on testnet (Sepolia) --------------------------------------------------
#   Bridgehub / chain id / DA pair are pinned from
#   l1-contracts/upgrade-envs/permanent-values/testnet.toml ([[ctm_contracts.ctms]] Era).
CHAIN_ID=301
L1_DA_VALIDATOR=0xcc46b186bd4515fa996adf3c40344ed7d546a65b   # post-upgrade RollupL1DAValidator for the Era CTM
L2_DA_SCHEME=blobs-and-pubdata-keccak256                     # EraVM rollup => BlobsAndPubdataKeccak256 (scheme 3)

: "${TENDERLY_SEPOLIA:?set TENDERLY_SEPOLIA to an L1 Sepolia RPC URL}"

# --- Step 1: build the AdminFunctions artifact + the protocol-ops binary -------
# `forge build` regenerates out/AdminFunctions.s.sol/AdminFunctions.json (and the
# committed zkstack-out copy is what the protocol-ops `sol!` macro reads).
echo "==> [1/2] building protocol-ops"
( cd "$REPO_ROOT/protocol-ops" && cargo build )

# --- Step 2: generate the Safe bundle against a Sepolia fork -------------------
# Forks Sepolia via anvil (no on-chain changes). The combined entrypoint emits
# ONE ChainAdmin.multicall wrapping [upgradeChainFromVersion, setDAValidatorPair].
echo "==> [2/2] generating chain-$CHAIN_ID upgrade + DA-pair Safe bundle"
mkdir -p "$OUT_DIR"
"$REPO_ROOT/protocol-ops/target/debug/protocol_ops" chain upgrade \
  --env testnet \
  --chain-id "$CHAIN_ID" \
  --l1-da-validator "$L1_DA_VALIDATOR" \
  --l2-da-commitment-scheme "$L2_DA_SCHEME" \
  --l1-rpc-url "$TENDERLY_SEPOLIA" \
  --out "$OUT_DIR"

echo
echo "Done. Safe bundle + manifest in: $OUT_DIR"
ls -1 "$OUT_DIR"
