// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./BridgehubBase.sol";
import "../../common/libraries/Diamond.sol";

contract BridgehubDiamondInit is BridgehubBase {
    function initialize(address _governor, IAllowList _allowList)
        external
        reentrancyGuardInitializer
        returns (bytes32)
    {
        require(bridgehubStorage.governor == address(0), "bridgehub1");
        bridgehubStorage.governor = _governor;
        bridgehubStorage.allowList = _allowList;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
