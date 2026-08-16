# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh

set -e

# Expected upstream Foundry version and commit for ordinary-EVM artifacts.
EXPECTED_VERSION="forge Version: 1.3.5-v1.3.5"
EXPECTED_COMMIT="9979a41b5"

# Check if Foundry is installed
if ! command -V forge &> /dev/null; then
  echo "Foundry is not installed. Please install upstream Foundry v1.3.5."
  exit 1
fi

# Get installed Foundry version and commit
FORGE_VERSION=$(forge --version | head -n 1)
FORGE_COMMIT=$(forge --version | grep "Commit SHA:" | cut -d' ' -f3 | cut -c1-9)

# Check version and commit separately
if [[ "$FORGE_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Incorrect Foundry version."
  echo "Expected: ${EXPECTED_VERSION}"
  echo "Found:    ${FORGE_VERSION}"
  echo "Install upstream Foundry v1.3.5."
  exit 1
fi

# Forge version output is broken on Linux returning VERGEN_IDEMPOTENT_OUTPUT instead of the commit hash.
# Accept both the expected commit and VERGEN_IDEMPOTENT_OUTPUT.
if [[ "$FORGE_COMMIT" != "$EXPECTED_COMMIT" && "$FORGE_COMMIT" != "VERGEN_ID" ]]; then
  echo "Incorrect Foundry commit."
  echo "Expected: ${EXPECTED_COMMIT}"
  echo "Found:    ${FORGE_COMMIT}"
  echo "Install upstream Foundry v1.3.5."
  exit 1
fi

if [ "$(git rev-parse --show-toplevel)" != "$PWD" ]; then
  echo "error: must be run at the root of matter-labs/era-contracts repository" >&2
  exit 1
fi

# Update submodules (just in case)
git submodule update --init --recursive

yarn

# Clean and rebuild the ordinary-EVM artifact roots.
forge clean --root da-contracts
forge clean --root l1-contracts

yarn --cwd da-contracts build:foundry
yarn --cwd l1-contracts build:foundry

yarn calculate-hashes:fix
