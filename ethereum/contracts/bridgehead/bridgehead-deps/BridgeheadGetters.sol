// SPDX-License-Identifier: MIT

import "./BridgeheadBase.sol";

pragma solidity ^0.8.13;

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
contract BridgeheadGetters is BridgeheadBase {
    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return bridgeheadStorage.governor;
    }

    /// @return The address of the allowList
    function getAllowList() external view returns (IAllowList) {
        return bridgeheadStorage.allowList;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getChainImplementation() external view returns (address) {
        return bridgeheadStorage.chainImplementation;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getChainProxyAdmin() external view returns (address) {
        return bridgeheadStorage.chainProxyAdmin;
    }

    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return bridgeheadStorage.priorityTxMaxGasLimit;
    }

    function getTotaProofSystems() external view returns (uint256) {
        return bridgeheadStorage.totalProofSystems;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getIsProofSystem(address _proofSystem) external view returns (bool) {
        return bridgeheadStorage.proofSystem[_proofSystem];
    }

    function getTotalChains() external view returns (uint256) {
        return bridgeheadStorage.totalChains;
    }

    function getChainContract(uint256 _chainId) external view returns (address) {
        return bridgeheadStorage.chainContract[_chainId];
    }

    function getChainProofSystem(uint256 _chainId) external view returns (address) {
        return bridgeheadStorage.chainProofSystem[_chainId];
    }
}
