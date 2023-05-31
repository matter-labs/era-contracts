// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../../bridge/L1ERC20Bridge.sol";

/// @author Matter Labs
contract L1ERC20BridgeTest is L1ERC20Bridge {
    constructor(IZkSync _zkSync, IAllowList _allowList) L1ERC20Bridge(_zkSync, _allowList) {}

    function getAllowList() public view returns (IAllowList) {
        return allowList;
    }

    function getZkSyncMailbox() public view returns (IMailbox) {
        return zkSync;
    }
}
