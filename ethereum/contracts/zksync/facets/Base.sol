// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../Storage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract Base is ReentrancyGuard, AllowListed {
    AppStorage internal s;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == s.governor, "1g"); // only by governor
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(s.validators[msg.sender], "1h"); // validator is not active
        _;
    }

    /// @notice Checks if `msg.sender` is the security council
    modifier onlySecurityCouncil() {
        require(msg.sender == s.upgrades.securityCouncil, "a9"); // not a security council
        _;
    }
}
