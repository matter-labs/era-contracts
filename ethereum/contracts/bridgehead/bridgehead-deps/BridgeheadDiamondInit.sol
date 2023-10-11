// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./BridgeheadBase.sol";

contract BridgeheadDiamondInit is BridgeheadBase {
    function initialize(address _governor, IAllowList _allowList) external reentrancyGuardInitializer returns (bytes32)  {
        require(bridgeheadStorage.governor == address(0), "bridgehead1");
        bridgeheadStorage.governor = _governor;
        bridgeheadStorage.allowList = _allowList;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
