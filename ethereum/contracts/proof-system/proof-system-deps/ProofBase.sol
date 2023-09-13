// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./ProofStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";

// import "../../bridgehead/chain-interfaces/IBridgeheadChain.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract ProofBase is ReentrancyGuard, AllowListed {
    ProofStorage internal proofStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == proofStorage.governor, "1g"); // only by governor
        _;
    }

    // /// @notice Checks if validator is active
    // modifier onlyValidator(uint256 _chainId) {
    //     require(proofStorage.validators[msg.sender], "1h"); // validator is not active
    //     _;
    // }

    // modifier onlyBridgeheadChain() {
    //     require(msg.sender == address(proofStorage.bridgeheadChainContract), "1i"); // message not sent by bridgehead
    //     _;
    // }

    modifier onlyBridgehead() {
        require(msg.sender == proofStorage.bridgeheadContract, "1i"); // message not sent by bridgehead
        _;
    }

    // modifier onlyChain() {
    //     require(IBridgeheadChain(proofStorage.bridgeheadChainContract).getGovernor() == msg.sender, "1j"); // wrong chainId
    //     _;
    // }

    // modifier onlySecurityCouncil() {
    //     require(msg.sender == proofStorage.upgrades.securityCouncil, "a9"); // not a security council
    //     _;
    // }
}
