// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DefaultUpgrade} from "./DefaultUpgrade.sol";
import {BaseBootstrapUpgrade} from "./BaseBootstrapUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title BootstrapUpgradeZKsyncOS
/// @notice The bootstrap engine: the {BaseBootstrapUpgrade} facet reinstall over the storage/L2
///         part of {DefaultUpgrade}, and the transition entrypoint of the latter, so the same
///         deployment serves the one-time edge into the registry model and any later transition.
contract BootstrapUpgradeZKsyncOS is DefaultUpgrade, BaseBootstrapUpgrade {
    constructor(ICTMRelease _genesisRelease) BaseBootstrapUpgrade(_genesisRelease) {}
}
