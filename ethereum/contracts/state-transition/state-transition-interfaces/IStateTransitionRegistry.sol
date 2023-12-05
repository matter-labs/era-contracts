// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/libraries/Diamond.sol";

interface IZkSyncStateTransitionRegistry {
    /// @notice
    function newChain(uint256 _chainId, address _governor, Diamond.DiamondCutData memory _diamondCut) external;

    // when a new Chain is added
    event StateTransitionNewChain(uint256 indexed _chainId, address indexed _stateTransitionChainContract);
}
