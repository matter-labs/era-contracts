// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./ChainStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract ChainBase is ReentrancyGuard, AllowListed {
    ChainStorage internal chainStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == chainStorage.governor, "12g"); // only by governor
        _;
    }

    /// @notice Checks if message to chain was sent by the proof system
    modifier onlyProofSystem() {
        require(chainStorage.proofSystem == msg.sender, "12h"); // wrong chainId
        _;
    }

    /// @notice Checks if message to chain was sent by the proof system
    modifier onlyProofChain() {
        require(chainStorage.proofChainContract == msg.sender, "13h"); // wrong chainId
        _;
    }
}
