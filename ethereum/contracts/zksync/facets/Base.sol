// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../Storage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract Base is ReentrancyGuard, AllowListed {
    AppStorage internal s;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == s.governor, "1g"); // only by governor
        _;
    }

    /// @notice Checks that the message sender is an active governor or its owner
    modifier onlyGovernorOrItsOwner() {
        address governorAddr = s.governor;
        address ownerAddr = Ownable(governorAddr).owner();
        require(msg.sender == ownerAddr || msg.sender == governorAddr, "Only by governor owner");
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(s.validators[msg.sender], "1h"); // validator is not active
        _;
    }
}
