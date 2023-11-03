// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

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

    /// @notice Checks that the message sender is an active governor or admin
    modifier onlyGovernorOrAdmin() {
        if (s.governor.code.length > 0) {
            try Ownable(s.governor).owner() returns (address admin) {
                require(msg.sender == s.governor || msg.sender == admin, "Only by governor or admin");
            } catch {
                require(msg.sender == s.governor, "Only by governor or admin");
            }
        } else {
            require(msg.sender == s.governor, "Only by governor or admin");
        }
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(s.validators[msg.sender], "1h"); // validator is not active
        _;
    }
}
