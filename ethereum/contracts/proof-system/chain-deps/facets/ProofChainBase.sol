// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../ProofChainStorage.sol";
import "../../../common/ReentrancyGuard.sol";
import "../../../common/AllowListed.sol";
import "../../../bridgehead/chain-interfaces/IBridgeheadChain.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract ProofChainBase is ReentrancyGuard, AllowListed {
    ProofChainStorage internal chainStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == chainStorage.governor, "1g1"); // only by governor
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(chainStorage.validators[msg.sender], "1h1"); // validator is not active
        _;
    }

    modifier onlyBridgeheadChain() {
        require(msg.sender == address(chainStorage.bridgeheadChainContract), "1i"); // message not sent by bridgehead
        _;
    }

    // modifier onlyChain() {
    //     require(IBridgeheadChain(chainStorage.bridgeheadChainContract).getGovernor() == msg.sender, "1j"); // wrong chainId
    //     _;
    // }

    modifier onlySecurityCouncil() {
        require(msg.sender == chainStorage.upgrades.securityCouncil, "a9"); // not a security council
        _;
    }
}
