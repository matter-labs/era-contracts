// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IL2ChainAssetHandler {
    function setSettlementLayerChainId(
        uint256 _previousSettlementLayerChainId,
        uint256 _currentSettlementLayerChainId
    ) external;
}

/// @title MockSystemContext
/// @notice Minimal SystemContext mock: lets any caller (not just the bootloader) set the
/// settlement layer chain ID, propagating to L2ChainAssetHandler so migrationNumber increments.
contract MockSystemContext {
    /// @dev Address of the L2ChainAssetHandler (USER_CONTRACTS_OFFSET + 0x0a = 0x1000a)
    IL2ChainAssetHandler constant L2_CHAIN_ASSET_HANDLER = IL2ChainAssetHandler(address(0x1000a));

    /// @notice The chainId of the settlement layer.
    uint256 public currentSettlementLayerChainId;

    /// @param _newSettlementLayerChainId The new settlement layer chain ID.
    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external {
        if (currentSettlementLayerChainId != _newSettlementLayerChainId) {
            L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId(currentSettlementLayerChainId, _newSettlementLayerChainId);
            currentSettlementLayerChainId = _newSettlementLayerChainId;
        }
    }
}
