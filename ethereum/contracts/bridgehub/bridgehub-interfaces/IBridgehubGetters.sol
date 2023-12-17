// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IBridgehubGetters {
    function governor() external view returns (address);

    /// @return The total number of batchs that were committed & verified & executed
    function stateTransitionIsRegistered(address _stateTransition) external view returns (bool);

    function stateTransition(uint256 _chainId) external view returns (address);
}
