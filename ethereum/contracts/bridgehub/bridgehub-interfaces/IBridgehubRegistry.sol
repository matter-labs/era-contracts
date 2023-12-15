// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IBridgehubBase.sol";
import "../../state-transition/state-transition-interfaces/IZkSyncStateTransition.sol";
import "../../common/interfaces/IAllowList.sol";
import "../../common/libraries/Diamond.sol";

interface IBridgehubRegistry {
    function newChain(
        uint256 _chainId,
        address _stateTransition,
        uint256 _salt,
        address _governor,
        bytes calldata _initData
    ) external returns (uint256 chainId);

    function newStateTransition(address _stateTransition) external;

    event NewChain(uint64 indexed chainId, address stateTransition, address indexed chainGovernance);
}
