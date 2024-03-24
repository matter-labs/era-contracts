// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {ZkSyncStateTransitionBase} from "../../state-transition/chain-deps/facets/ZkSyncStateTransitionBase.sol";

contract DiamondProxyTest is ZkSyncStateTransitionBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function setFreezability(bool _freeze) external returns (bytes32) {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();
        diamondStorage.isFrozen = _freeze;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
