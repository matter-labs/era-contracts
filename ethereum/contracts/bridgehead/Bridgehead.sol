// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./bridgehead-deps/Registry.sol";
import "./bridgehead-deps/Router.sol";
import "./bridgehead-deps/BridgeheadGetters.sol";

contract Bridgehead is BridgeheadGetters, Router, Registry {
    function initialize(
        address _governor,
        address _chainImplementation,
        address _chainProxyAdmin,
        IAllowList _allowList,
        uint256 _priorityTxMaxGasLimit
    ) public {
        require(bridgeheadStorage.chainImplementation == address(0), "r1");
        bridgeheadStorage.governor = _governor;
        bridgeheadStorage.chainImplementation = _chainImplementation;
        bridgeheadStorage.chainProxyAdmin = _chainProxyAdmin;
        bridgeheadStorage.allowList = _allowList;
        bridgeheadStorage.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }
}
