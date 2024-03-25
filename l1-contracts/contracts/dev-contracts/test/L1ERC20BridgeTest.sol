// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1ERC20Bridge} from "../../bridge/L1ERC20Bridge.sol";
import {IBridgehub, IL1SharedBridge} from "../../bridge/interfaces/IL1SharedBridge.sol";

/// @author Matter Labs
contract L1ERC20BridgeTest is L1ERC20Bridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor(IBridgehub _zkSync) L1ERC20Bridge(IL1SharedBridge(address(0))) {}
}
