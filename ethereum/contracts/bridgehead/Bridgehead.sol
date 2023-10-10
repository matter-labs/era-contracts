// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./bridgehead-deps/Registry.sol";
import "./bridgehead-deps/BridgeheadMailbox.sol";
import "./bridgehead-deps/BridgeheadGetters.sol";

contract Bridgehead is BridgeheadGetters, BridgeheadMailbox, Registry {
    function initialize(address _governor, IAllowList _allowList) public {
        require(bridgeheadStorage.governor == address(0), "bridgehead1");
        bridgeheadStorage.governor = _governor;
        bridgeheadStorage.allowList = _allowList;
    }
}
