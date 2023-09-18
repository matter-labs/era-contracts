// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./BridgeheadStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract BridgeheadBase is ReentrancyGuard, AllowListed {
    BridgeheadStorage internal bridgeheadStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == bridgeheadStorage.governor, "12g"); // only by governor
        _;
    }

    modifier onlyChainContract(uint256 _chainId) {
        require(msg.sender == bridgeheadStorage.chainContract[_chainId], "12c"); // only by chain contract
        _;
    }
}
