// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1ERC20Bridge} from "../bridge/L1ERC20Bridge.sol";
import {IL1AssetRouter} from "../bridge/interfaces/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "../bridge/interfaces/IL1NativeTokenVault.sol";

contract DummyL1ERC20Bridge is L1ERC20Bridge {
    constructor(
        IL1AssetRouter _l1SharedBridge,
        IL1NativeTokenVault _l1NativeTokenVault
    ) L1ERC20Bridge(_l1SharedBridge, _l1NativeTokenVault, 1) {}

    function setValues(address _l2SharedBridge, address _l2TokenBeacon, bytes32 _l2TokenProxyBytecodeHash) external {
        l2Bridge = _l2SharedBridge;
        l2TokenBeacon = _l2TokenBeacon;
        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
