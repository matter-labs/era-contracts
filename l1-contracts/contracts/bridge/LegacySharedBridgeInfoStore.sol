// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ZeroAddress, ZeroChainId} from "../common/L1ContractErrors.sol";

// Struct to store legacy bridge information for a chain
struct ChainLegacyBridgeInfo {
    address l2BridgeProxyOwner;
    address l2BridgeBeaconProxyOwner;
}

contract LegacySharedBridgeInfoStore is Ownable2Step {
    /// @notice Mapping to store ChainLegacyBridgeInfo based on chainId (uint256)
    mapping(uint256 chainId => ChainLegacyBridgeInfo info) private chainBridgeInfo;

    /// @notice Event to log when new ChainLegacyBridgeInfo is added or updated
    event BridgeInfoUpdated(uint256 indexed chainId, address l2BridgeProxyOwner, address l2BridgeBeaconProxyOwner);

    /// @notice Function to allow the owner to set bridge information for a chain
    function setChainLegacyBridgeInfo(uint256 _chainId, address _l2BridgeProxyOwner, address _l2BridgeBeaconProxyOwner) external onlyOwner {
        if(_l2BridgeProxyOwner == address(0) || _l2BridgeBeaconProxyOwner == address(0)) {
            revert ZeroAddress();
        }
        if(_chainId == 0) {
            revert ZeroChainId();
        }

        chainBridgeInfo[_chainId] = ChainLegacyBridgeInfo({
            l2BridgeProxyOwner: _l2BridgeProxyOwner,
            l2BridgeBeaconProxyOwner: _l2BridgeBeaconProxyOwner
        });

        emit BridgeInfoUpdated(_chainId, _l2BridgeProxyOwner, _l2BridgeBeaconProxyOwner);
    }

    /// @notice Function to get bridge information for a specific chainId
    function getChainLegacyBridgeInfo(uint256 _chainId) external view returns (ChainLegacyBridgeInfo memory info) {
        info = chainBridgeInfo[_chainId];

        if(info.l2BridgeBeaconProxyOwner == address(0) || )
    }
}
