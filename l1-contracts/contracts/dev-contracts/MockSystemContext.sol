// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IL2ChainAssetHandler {
    function setSettlementLayerChainId(
        uint256 _previousSettlementLayerChainId,
        uint256 _currentSettlementLayerChainId
    ) external;
}

/// @title MockSystemContext
/// @notice A minimal mock for testing that supports settlement layer chain ID management.
/// @dev Unlike the real SystemContext (which uses onlyCallFromBootloader), this mock allows
/// any caller to set the settlement layer chain ID. The setter propagates to L2ChainAssetHandler
/// to properly increment migrationNumber, which is required for Token Balance Migration.
contract MockSystemContext {
    /// @dev Address of the L2ChainAssetHandler (USER_CONTRACTS_OFFSET + 0x0a = 0x1000a)
    IL2ChainAssetHandler constant L2_CHAIN_ASSET_HANDLER = IL2ChainAssetHandler(address(0x1000a));

    /// @notice The chainId of the settlement layer.
    uint256 public currentSettlementLayerChainId;

    /// @notice Set the settlement layer chain ID and propagate to L2ChainAssetHandler.
    /// @dev In production, only the bootloader can call this. In tests, any caller is allowed.
    /// @param _newSettlementLayerChainId The new settlement layer chain ID.
    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external {
        if (currentSettlementLayerChainId != _newSettlementLayerChainId) {
            L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId(currentSettlementLayerChainId, _newSettlementLayerChainId);
            currentSettlementLayerChainId = _newSettlementLayerChainId;
        }
    }
}
