// SPDX-License-Identifier: MIT

import "./BridgehubBase.sol";

pragma solidity ^0.8.13;

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
contract BridgehubGettersFacet is BridgehubBase {
    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return bridgehubStorage.governor;
    }

    /// @return The address of the allowList
    function getAllowList() external view returns (IAllowList) {
        return bridgehubStorage.allowList;
    }

    /// @return The total number of batches that were committed & verified & executed
    function getIsStateTransition(address _stateTransition) external view returns (bool) {
        return bridgehubStorage.stateTransitionIsRegistered[_stateTransition];
    }

    function getChainStateTransition(uint256 _chainId) external view returns (address) {
        return bridgehubStorage.stateTransition[_chainId];
    }
}
