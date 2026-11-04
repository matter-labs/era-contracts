// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Diamond} from "../libraries/Diamond.sol";

/// @title Interface for upgrading a ZK chain from a specific protocol version.
/// @dev Shared by IAdmin (diamond facet) and IValidatorTimelock to ensure signature parity at compile time.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainUpgrader {
    /// @notice Perform the upgrade from the current protocol version with the corresponding upgrade data.
    /// @param _chainAddress The address of the chain being upgraded.
    /// @param _protocolVersion The current protocol version from which upgrade is executed.
    /// @param _cutData The diamond cut parameters that is executed in the upgrade.
    function upgradeChainFromVersion(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;
}
