// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../bridge/L1ERC20Bridge.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import "../../bridge/interfaces/IL1SharedBridge.sol";

/// @author Matter Labs
contract L1ERC20BridgeTest is L1ERC20Bridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor(IBridgehub _zkSync) L1ERC20Bridge(IL1SharedBridge(address(0))) {}

    // function getBridgehub() public view returns (IBridgehub) {
    //     return bridgehub;
    // }
}
