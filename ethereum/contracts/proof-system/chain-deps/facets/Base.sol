// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../ProofChainStorage.sol";
import "../../../common/ReentrancyGuard.sol";
import "../../../common/AllowListed.sol";
import "../../../bridgehead/chain-interfaces/IBridgeheadChain.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
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
        require(msg.sender == address(chainStorage.bridgeheadChainContract), "1ii"); // message not sent by bridgehead
        _;
    }

    modifier onlyProofSystem() {
        require(msg.sender == address(chainStorage.proofSystem), "1ij"); // message not sent by bridgehead
        _;
    }

    // modifier onlyChain() {
    //     require(IBridgeheadChain(chainStorage.bridgeheadChainContract).getGovernor() == msg.sender, "1j"); // wrong chainId
    //     _;
    // }

    /// @notice Checks that the message sender is an active governor or admin
    modifier onlyGovernorOrAdmin() {
        require(msg.sender == chainStorage.governor || msg.sender == chainStorage.admin, "Only by governor or admin");
        _;
    }
}
