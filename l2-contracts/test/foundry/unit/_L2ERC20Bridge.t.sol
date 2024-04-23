// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "contracts/bridge/L2ERC20Bridge.sol";

/// @title Test Wrapper for L2ERC20Bridge to Facilitate Testing by Manipulating Internal State
contract L2ERC20BridgeTestWrapper is L2ERC20Bridge {
    /// @dev Sets a mapping from L2 to L1 token addresses, used for testing purposes
    /// @param l2Token The address of the L2 token
    /// @param l1Token The address of the corresponding L1 token
    function setTokenAddress(address l2Token, address l1Token) public {
        l1TokenAddress[l2Token] = l1Token;
    }
}
