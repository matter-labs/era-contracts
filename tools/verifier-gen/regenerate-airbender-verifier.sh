#!/usr/bin/env bash
#
# Regenerate the Airbender PLONK verifier contract from the SNARK verification
# key published by `eravm-airbender-verifier`.
#
# The prover server (`airbender_prover_server`) proves against the `snark_vk.json`
# from a pinned `eravm-airbender-verifier` release; the on-chain verifier must be
# generated from the *same* key or proofs won't verify. This script downloads
# that key and runs the codegen so the two never drift.
#
# Usage:
#   ./regenerate-airbender-verifier.sh [<tag>]
#
# <tag> defaults to the version below; pass one to regenerate against a different
# release (must match the tag pinned in `airbender_prover_server/Cargo.toml`).

set -euo pipefail

# Keep in sync with the `zksync_airbender_verifier` tag in
# `airbender_prover_server/Cargo.toml`.
DEFAULT_TAG="v31.0.0"
TAG="${1:-$DEFAULT_TAG}"

REPO_URL="https://github.com/matter-labs/eravm-airbender-verifier"
ASSET="snark_vk.json"

# Resolve paths relative to this script so it can be run from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
VK_PATH="$DATA_DIR/airbender_snark_vk.json"
# Codegen writes here (see `resolve_jobs` for the `airbender` variant).
GENERATED_PATH="$DATA_DIR/AirbenderVerifierPlonk.sol"
# Final home of the committed contract.
CONTRACT_DEST="$SCRIPT_DIR/../../l1-contracts/contracts/state-transition/verifiers/AirbenderVerifierPlonk.sol"

echo "Downloading $ASSET from $REPO_URL release $TAG"
curl --fail --location --silent --show-error \
    "$REPO_URL/releases/download/$TAG/$ASSET" \
    --output "$VK_PATH"

echo "Generating Airbender PLONK verifier contract"
(cd "$SCRIPT_DIR" && cargo run --release --bin zksync_verifier_contract_generator -- --variant airbender)

cp "$GENERATED_PATH" "$CONTRACT_DEST"
echo "Wrote $CONTRACT_DEST"
echo "Done. Review the diff and commit the regenerated contract."
