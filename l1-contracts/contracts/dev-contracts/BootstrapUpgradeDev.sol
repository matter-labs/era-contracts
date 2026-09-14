// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgrade} from "../upgrades/DefaultUpgrade.sol";
import {BaseBootstrapUpgrade} from "../upgrades/BaseBootstrapUpgrade.sol";
import {ICTMRelease} from "../upgrades/registry/objects/ICTMRelease.sol";

/// @notice Test-only bootstrap engine: the production `BootstrapUpgradeZKsyncOS` facet reinstall
///         (remove the departing diamond's live routing, install the pinned release's facet set)
///         over the plain `DefaultUpgrade` L2 handling. The anvil registry harness pins it for its
///         bootstrap edge: the ZKsync OS engine's per-chain rewrite requires the real `L2V34Upgrade`
///         calldata shape, and the harness's delegate is a no-op stand-in.
contract BootstrapUpgradeDev is DefaultUpgrade, BaseBootstrapUpgrade {
    constructor(ICTMRelease _genesisRelease) BaseBootstrapUpgrade(_genesisRelease) {}
}
