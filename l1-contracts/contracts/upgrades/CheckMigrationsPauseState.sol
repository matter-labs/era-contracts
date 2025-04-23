// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IBridgehub} from "../bridgehub/IBridgehub.sol";

/// @title Check Migrations Pause State
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract will be used by the governance to ensure that migrations are paused or unpaused before proceeding.
contract CheckMigrationsPauseState {
    /// @notice Address of bridgehub to check.
    IBridgehub public immutable BRIDGEHUB;

    /// @dev Initializes the contract with immutable values for `BRIDGEHUB`.
    /// @param bridgehub The address of bridgehub on the chain.
    constructor(address bridgehub) {
        BRIDGEHUB = IBridgehub(bridgehub);
    }

    /// @notice Check if migrations are paused
    function requireMigrationsPaused() external {
        require(BRIDGEHUB.migrationPaused());
    }

    /// @notice Check if migrations are unpaused
    function requireMigrationsUnpaused() external {
        require(!BRIDGEHUB.migrationPaused());
    }
}
