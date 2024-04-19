// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1ERC20Bridge} from "../bridge/L1ERC20Bridge.sol";
import {IL1SharedBridge} from "../bridge/interfaces/IL1SharedBridge.sol";

contract DummyL1ERC20Bridge is L1ERC20Bridge {
    constructor(IL1SharedBridge _l1SharedBridge) L1ERC20Bridge(_l1SharedBridge) {}

    function setValues(address _l2Bridge, address _l2TokenBeacon, bytes32 _l2TokenProxyBytecodeHash) external {
        l2Bridge = _l2Bridge;
        l2TokenBeacon = _l2TokenBeacon;
        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
    }
}
