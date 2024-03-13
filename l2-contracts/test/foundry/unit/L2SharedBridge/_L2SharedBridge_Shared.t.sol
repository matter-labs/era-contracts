// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {L2SharedBridge} from "solpp/bridge/L2SharedBridge.sol";

contract L2SharedBridgeTestWrapper is L2SharedBridge {
    function setTokenAddress(address l2Token, address l1Token) public {
        l1TokenAddress[l2Token] = l1Token;
    }
}