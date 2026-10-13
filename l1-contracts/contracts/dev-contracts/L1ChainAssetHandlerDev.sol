// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1ChainAssetHandler} from "../core/chain-asset-handler/L1ChainAssetHandler.sol";
import {MigrationInterval} from "../core/chain-asset-handler/IChainAssetHandler.sol";

/// @notice Test-only variant of `L1ChainAssetHandler` for the Anvil harness and foundry tests.
/// @dev It re-enables chain migrations. Production records migration numbers and intervals only
/// during a real chain migration, whose `Migrator.forwardedBridgeBurn` invariants
/// (`priorityTree.getSize() == 0`, `totalBatchesCommitted == totalBatchesExecuted`) a sequencer-less
/// harness cannot meet, so the setters below reproduce that state. A fresh copy is installed behind
/// the production proxy, so the L1-side immutables (`BRIDGEHUB`, `L1_CHAIN_ID`, `ETH_TOKEN_ASSET_ID`)
/// keep their production values.
/// @dev Gated by `onlyOwner` (same modifier that gates `setAddresses`), so the
/// setters cannot be reached from any non-governance surface.
contract L1ChainAssetHandlerDev is L1ChainAssetHandler {
    constructor(address _owner, address _bridgehub) L1ChainAssetHandler(_owner, _bridgehub) {}

    /// @dev For local testing only.
    function setMigrationNumberForTesting(uint256 _chainId, uint256 _migrationNumber) external onlyOwner {
        migrationNumber[_chainId] = _migrationNumber;
    }

    /// @dev For local testing only. Production records intervals only while a chain migrates
    /// (`_recordMigrationToSL` / `_recordMigrationFromSL`); tests reproduce that state through this call.
    function setMigrationIntervalForTesting(
        uint256 _chainId,
        uint256 _migrationNumber,
        MigrationInterval calldata _interval
    ) external onlyOwner {
        _migrationInterval[_chainId][_migrationNumber] = _interval;
    }

    /// @dev Re-enables chain migrations (disabled in production via `CHAIN_MIGRATIONS_ENABLED` in
    /// `Config.sol`) so tests keep exercising the migration machinery.
    function _getChainMigrationsEnabled() internal pure override returns (bool) {
        return true;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
