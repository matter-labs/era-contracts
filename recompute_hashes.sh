# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh

set -e

# Expected Foundry version and commit
EXPECTED_VERSION="forge 0.0.4"
EXPECTED_COMMIT="ae913af"

# Check if Foundry is installed
if ! command -V forge &> /dev/null; then
  echo "Foundry is not installed. Please install it using foundryup-zksync with commit ${EXPECTED_COMMIT}."
  exit 1
fi

# Get installed Foundry version (first line only)
FORGE_OUTPUT=$(forge --version | head -n 1)

# Forge 0.0.4 version output is broken on Linux returning VERGEN_IDEMPOTENT_OUTPUT instead of the commit hash.
# So we accept both the expected commit and VERGEN_IDEMPOTENT_OUTPUT with regex:
# - must start with "forge 0.0.4"
# - must have "(...)" after it
# - inside parentheses: either the expected commit OR VERGEN_IDEMPOTENT_OUTPUT
if [[ ! "$FORGE_OUTPUT" =~ ^${EXPECTED_VERSION}\ \(((${EXPECTED_COMMIT})|VERGEN_IDEMPOTENT_OUTPUT).* ]]; then
  echo "Incorrect Foundry version."
  echo "Expected:"
  echo "  ${EXPECTED_VERSION} (${EXPECTED_COMMIT})"
  echo "  or ${EXPECTED_VERSION} (VERGEN_IDEMPOTENT_OUTPUT ...)"
  echo "Found:"
  echo "  ${FORGE_OUTPUT}"
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
