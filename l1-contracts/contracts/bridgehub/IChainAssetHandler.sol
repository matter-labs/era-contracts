// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IBridgehub} from "./IBridgehub.sol";

import {IAssetHandler} from "../bridge/interfaces/IAssetHandler.sol";
import {IL1AssetHandler} from "../bridge/interfaces/IL1AssetHandler.sol";

interface IChainAssetHandler is IAssetHandler, IL1AssetHandler {
    // function BRIDGE_HUB() external view returns (IBridgehub);

    // function addNewChain(uint256 _chainId) external;

    /// @notice Emitted when the bridging to the chain is started.
    /// @param chainId Chain ID of the ZK chain
    /// @param assetId Asset ID of the token for the zkChain's CTM
    /// @param settlementLayerChainId The chain id of the settlement layer the chain migrates to.
    event MigrationStarted(uint256 indexed chainId, bytes32 indexed assetId, uint256 indexed settlementLayerChainId);

    /// @notice Emitted when the bridging to the chain is complete.
    /// @param chainId Chain ID of the ZK chain
    /// @param assetId Asset ID of the token for the zkChain's CTM
    /// @param zkChain The address of the ZK chain on the chain where it is migrated to.
    event MigrationFinalized(uint256 indexed chainId, bytes32 indexed assetId, address indexed zkChain);
}
