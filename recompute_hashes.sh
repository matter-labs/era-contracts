# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh

set -e

# Expected Foundry version and commit
EXPECTED_VERSION="forge Version: 1.3.5-foundry-zksync-v0.0.29"
EXPECTED_COMMIT="362c9aa7c41962ac7af5133c71095fd82986d6cf"

# Check if Foundry is installed
if ! command -V forge &> /dev/null; then
  echo "Foundry is not installed. Please install it using foundryup-zksync with commit ${EXPECTED_COMMIT}."
  exit 1
fi

# Get installed Foundry version (first line only)
FORGE_OUTPUT=$(forge --version | head -n 1)

# Accept anything that begins with: "${EXPECTED_VERSION}"
EXPECTED_PREFIX="${EXPECTED_VERSION}"
if [[ "$FORGE_OUTPUT" != "$EXPECTED_PREFIX"* ]]; then
  echo "Incorrect Foundry version."
  echo "Expected something starting with: ${EXPECTED_PREFIX}"
  echo "Found:    ${FORGE_OUTPUT}"
  echo "Run: foundryup-zksync --commit ${EXPECTED_COMMIT}"
  exit 1
fi

if [ "$(git rev-parse --show-toplevel)" != "$PWD" ]; then
  echo "error: must be run at the root of matter-labs/era-contracts repository" >&2
  exit 1
fi

# Update submodules (just in case)
git submodule update --init --recursive

yarn

# Cleanup everything and recompile
forge clean --root da-contracts
yarn --cwd l1-contracts clean
forge clean --root l1-contracts
yarn --cwd l2-contracts clean
forge clean --root l2-contracts
yarn --cwd system-contracts clean
forge clean --root system-contracts

yarn --cwd da-contracts build:foundry
yarn --cwd l1-contracts build:foundry
yarn --cwd l2-contracts build:foundry
yarn --cwd system-contracts build:foundry

yarn calculate-hashes:fix
