// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IStateTransitionBase.sol";
import "./IStateTransitionRegistry.sol";
import "./IStateTransitionGetters.sol";
import "./IStateTransitionInit.sol";

interface IStateTransition is
    IStateTransitionBase,
    IStateTransitionGetters,
    IStateTransitionInit,
    IStateTransitionRegistry
{}
