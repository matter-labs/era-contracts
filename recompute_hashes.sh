# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh

set -e

# Expected Foundry version and commit
EXPECTED_VERSION="0.0.4"
EXPECTED_COMMIT="ae913af"

# Check if Foundry is installed
if ! command -V forge &> /dev/null; then
  echo "Foundry is not installed. Please install it using foundryup-zksync with commit ${EXPECTED_COMMIT}."
  exit 1
fi

# Get installed Foundry version
FORGE_OUTPUT=$(forge --version)
INSTALLED_VERSION=$(echo "$FORGE_OUTPUT" | awk '{print $2}')
INSTALLED_COMMIT=$(echo "$FORGE_OUTPUT" | awk -F'[()]' '{print $2}' | awk '{print $1}')

# Check if Foundry version is as expected
if [ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ] || [ "$INSTALLED_COMMIT" != "$EXPECTED_COMMIT" ]; then
  echo "Incorrect Foundry version."
  echo "Expected: forge ${EXPECTED_VERSION} (${EXPECTED_COMMIT})"
  echo "Found:    ${FORGE_OUTPUT})"
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
