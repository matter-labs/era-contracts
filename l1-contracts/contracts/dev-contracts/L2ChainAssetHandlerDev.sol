// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2ChainAssetHandler} from "../core/chain-asset-handler/L2ChainAssetHandler.sol";

/// @notice Test-only variant of `L2ChainAssetHandler` for the Anvil multichain harness.
/// @dev In production, `migrationNumber` is updated by `bridgeBurn` (increment) and
/// `bridgeMint` (overwrite). Both paths go through the migrating chain's ZKChain
/// Migrator facet, which enforces `priorityTree.getSize() == 0`. Processing the
/// priority tree requires a running sequencer, which the Anvil-based harness does
/// not have. This dev variant exposes a direct setter so the harness can simulate
/// the state transition without a sequencer, gated by `onlyUpgrader` to match the
/// access surface of the production update paths.
contract L2ChainAssetHandlerDev is L2ChainAssetHandler {
    /// @dev For local testing only.
    function setMigrationNumberForTesting(uint256 _chainId, uint256 _migrationNumber) external onlyUpgrader {
        migrationNumber[_chainId] = _migrationNumber;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
