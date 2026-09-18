// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1ChainAssetHandler} from "../core/chain-asset-handler/L1ChainAssetHandler.sol";

/// @notice Test-only variant of `L1ChainAssetHandler` for the Anvil multichain harness.
/// @dev In production, `migrationNumber` on L1 is bumped by `bridgeMint` when a
/// chain returns from Gateway to L1 as part of the chain-level migrate-from-gateway
/// governance flow. That flow ultimately invokes `Migrator.forwardedBridgeBurn` on
/// the migrating chain's Gateway diamond proxy, which enforces
/// `priorityTree.getSize() == 0` and `totalBatchesCommitted == totalBatchesExecuted` —
/// invariants that a sequencer-less Anvil harness can only satisfy via a matching
/// `MigratorFacetDev` dev-variant, installed via `anvil_setCode` after a fresh-deploy
/// copy of this contract is built so the L1-side immutables (`BRIDGEHUB`,
/// `L1_CHAIN_ID`, `ETH_TOKEN_ASSET_ID`) are baked in with the production values.
/// @dev Gated by `onlyOwner` (same modifier that gates `setAddresses`), so the
/// setter cannot be reached from any non-governance surface.
contract L1ChainAssetHandlerDev is L1ChainAssetHandler {
    constructor(address _owner, address _bridgehub) L1ChainAssetHandler(_owner, _bridgehub) {}

    /// @dev For local testing only.
    function setMigrationNumberForTesting(uint256 _chainId, uint256 _migrationNumber) external onlyOwner {
        migrationNumber[_chainId] = _migrationNumber;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
