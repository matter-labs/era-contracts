// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Diamond} from "../libraries/Diamond.sol";

/// @title The cut-TAKING chain upgrade entrypoint, which v31 through v34 Admin facets expose.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice v35 replaced it with the cut-reading form on `IChainUpgrader`.
// TODO(v36): DELETE once no chain can depart a pre-v35 version.
interface IAdminWithCut {
    /// @notice Executes the upgrade from `_protocolVersion` with the handed cut, which the chain
    ///         checks against the cut hash its ChainTypeManager committed.
    /// @param _chainAddress The address of the chain being upgraded.
    /// @param _protocolVersion The current protocol version from which upgrade is executed.
    /// @param _cutData The diamond cut parameters that is executed in the upgrade.
    function upgradeChainFromVersion(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;
}
