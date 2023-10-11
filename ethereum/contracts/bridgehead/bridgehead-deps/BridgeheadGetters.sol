// SPDX-License-Identifier: MIT

import "./BridgeheadBase.sol";

pragma solidity ^0.8.13;

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
contract BridgeheadGettersFacet is BridgeheadBase {
    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return bridgeheadStorage.governor;
    }

    /// @return The address of the allowList
    function getAllowList() external view returns (IAllowList) {
        return bridgeheadStorage.allowList;
    }

    /// @return The total number of batches that were committed & verified & executed
    function getIsProofSystem(address _proofSystem) external view returns (bool) {
        return bridgeheadStorage.proofSystemIsRegistered[_proofSystem];
    }

    function getChainProofSystem(uint256 _chainId) external view returns (address) {
        return bridgeheadStorage.proofSystem[_chainId];
    }
}
