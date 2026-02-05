# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh

set -e

# Expected Foundry version and commit
EXPECTED_VERSION="forge Version: 1.3.5-foundry-zksync-v0.1.5"
EXPECTED_COMMIT="807f47ace"

# Check if Foundry is installed
if ! command -V forge &> /dev/null; then
  echo "Foundry is not installed. Please install it using \"foundryup-zksync -i 0.1.5\"."
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
  echo "Run: foundryup-zksync -i 0.1.5"
  exit 1
fi

if [[ "$FORGE_COMMIT" != "$EXPECTED_COMMIT" ]]; then
  echo "Incorrect Foundry commit."
  echo "Expected: ${EXPECTED_COMMIT}"
  echo "Found:    ${FORGE_COMMIT}"
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
yarn --cwd da-contracts clean
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
