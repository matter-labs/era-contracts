// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../bridge/L1ERC20Bridge.sol";
import {IMailbox} from "../../zksync/interfaces/IMailbox.sol";

/// @author Matter Labs
contract L1ERC20BridgeTest is L1ERC20Bridge {
    constructor(IZkSync _zkSync) L1ERC20Bridge(_zkSync) {}

    function getZkSyncMailbox() public view returns (IMailbox) {
        return zkSync;
    }
}
