// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../zksync/libraries/Diamond.sol";
import "../../zksync/facets/Base.sol";

contract DiamondProxyTest is Base {
    function setFreezability(bool _freeze) external returns (bytes32) {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();
        diamondStorage.isFrozen = _freeze;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
