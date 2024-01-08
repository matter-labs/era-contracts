// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./IStateTransitionRegistry.sol";
import "./IStateTransitionGetters.sol";
import "./IStateTransitionInit.sol";

interface IZkSyncStateTransition is
    IZkSyncStateTransitionGetters,
    IZkSyncStateTransitionInit,
    IZkSyncStateTransitionRegistry
{}
