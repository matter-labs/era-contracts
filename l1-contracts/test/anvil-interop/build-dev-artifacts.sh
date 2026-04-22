#!/bin/bash
# Build the Solidity artifacts the Anvil multichain harness needs at test time.
#
# The harness does not rely on a full `forge build` of the repo — it only needs
# the handful of dev-only contracts it deploys / installs at test start-up, plus
# `TransparentUpgradeableProxy` for the L1 proxy-upgrade path. Building just
# these keeps the CI step fast (<10s) and makes the dependency set explicit.
#
# Contracts built:
#
#   DummyInteropRecipient
#     Deployed at test runtime via `ContractFactory` to receive cross-chain
#     interop bundles.
#
#   L2ChainAssetHandlerDev
#     Installed over the production `L2ChainAssetHandler` at
#     `L2_CHAIN_ASSET_HANDLER_ADDR` on the Gateway to expose
#     `setMigrationNumberForTesting` for reverse-TBM setup.
#
#   L1ChainAssetHandlerDev
#     Fresh-deployed on L1; the `L1ChainAssetHandler` `TransparentUpgradeableProxy`
#     is then upgraded to it via the real admin surface to expose
#     `setMigrationNumberForTesting` for reverse-TBM setup.
#
#   TestnetERC20Token
#     Deployed at test runtime to exercise the
#     `TokenBalanceNotMigratedToGateway` revert path on a freshly-registered,
#     unmigrated asset (spec 10).
#
#   TransparentUpgradeableProxy
#     `ITransparentUpgradeableProxy` ABI loaded by the harness to call
#     `upgradeTo` when installing `L1ChainAssetHandlerDev` through the real
#     proxy-admin surface.

set -euo pipefail

cd "$(dirname "$0")/../.."

forge build \
  contracts/dev-contracts/test/DummyInteropRecipient.sol \
  contracts/dev-contracts/L2ChainAssetHandlerDev.sol \
  contracts/dev-contracts/L1ChainAssetHandlerDev.sol \
  contracts/dev-contracts/TestnetERC20Token.sol \
  node_modules/@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol
