// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IBridgehubGetters {
    function getGovernor() external view returns (address);

    /// @return The total number of batchs that were committed & verified & executed
    function getIsStateTransition(address _stateTransition) external view returns (bool);

    function getStateTransition(uint256 _chainId) external view returns (address);
}
