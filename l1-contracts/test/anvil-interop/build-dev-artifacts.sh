#!/bin/bash
# Build the Solidity artifacts the Anvil multichain harness needs at test time.
#
# The harness does not rely on a full `forge build` of the repo — it only needs
# the handful of dev-only contracts it deploys at test runtime. Building just
# these keeps the CI step fast (<10s) and makes the dependency set explicit.
#
# Contracts built:
#
#   DummyInteropRecipient
#     Deployed at test runtime via `ContractFactory` to receive cross-chain
#     interop bundles.
#
#   TestnetERC20Token
#     Deployed at test runtime to exercise a freshly-registered,
#     migrated chain-native asset.

set -euo pipefail

cd "$(dirname "$0")/../.."

forge build \
  contracts/dev-contracts/test/DummyInteropRecipient.sol \
  contracts/dev-contracts/TestnetERC20Token.sol
