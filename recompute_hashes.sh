# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh

# Expected Foundry version and commit
EXPECTED_VERSION="0.0.2"
EXPECTED_COMMIT="27360d4c8"

# Check if Foundry is installed
if ! command -V forge &> /dev/null; then
  echo "Foundry is not installed. Please install it using foundryup-zksync with commit ${EXPECTED_COMMIT}."
  return 1
fi

# Get installed Foundry version
FORGE_OUTPUT=$(forge --version)
INSTALLED_VERSION=$(echo "$FORGE_OUTPUT" | awk '{print $2}')
INSTALLED_COMMIT=$(echo "$FORGE_OUTPUT" | awk -F'[()]' '{print $2}' | awk '{print $1}')

# Check if Foundry version is as expected
if [ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ] || [ "$INSTALLED_COMMIT" != "$EXPECTED_COMMIT" ]; then
  echo "Incorrect Foundry version."
  echo "Expected: forge ${EXPECTED_VERSION} (${EXPECTED_COMMIT})"
  echo "Found:    forge ${INSTALLED_VERSION} (${INSTALLED_COMMIT})"
  return 1
fi

# Update submodules (just in case)
git submodule update --init --recursive


# Cleanup everything and recompile
pushd da-contracts && \
forge clean && popd && \
pushd l1-contracts && \
yarn clean && forge clean && popd && \
pushd l2-contracts && \
yarn clean && forge clean && popd && \
pushd system-contracts && \
yarn clean && forge clean && popd && \
pushd da-contracts && \
yarn build:foundry && popd && \
pushd l1-contracts && \
yarn build:foundry && popd && \
pushd l2-contracts && \
yarn build:foundry && popd && \
pushd system-contracts && \
yarn build:foundry && popd && \
yarn calculate-hashes:fix
