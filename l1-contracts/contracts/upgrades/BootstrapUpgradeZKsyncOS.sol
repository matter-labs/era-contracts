// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";
import {BaseBootstrapUpgrade} from "./BaseBootstrapUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title BootstrapUpgradeZKsyncOS
/// @notice The production bootstrap engine for ZKsync OS chains: the {BaseBootstrapUpgrade} facet
///         reinstall over the per-chain L2 handling of {DefaultUpgradeZKsyncOS}.
contract BootstrapUpgradeZKsyncOS is DefaultUpgradeZKsyncOS, BaseBootstrapUpgrade {
    constructor(ICTMRelease _genesisRelease) BaseBootstrapUpgrade(_genesisRelease) {}

    /// @inheritdoc BaseZkSyncUpgrade
    /// @dev Linearization only: both bases reach `_upgrade`, and the ZKsync OS per-chain handling
    ///      is the one that must run.
    function _upgrade(
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _verifier,
        L2CanonicalTransaction memory _l2ProtocolUpgradeTx
    ) internal override(BaseZkSyncUpgrade, DefaultUpgradeZKsyncOS) returns (bytes32) {
        return super._upgrade(_newProtocolVersion, _upgradeTimestamp, _verifier, _l2ProtocolUpgradeTx);
    }
}
