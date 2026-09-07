// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgrade} from "../upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "../upgrades/BaseZkSyncUpgrade.sol";
import {ICTMRelease} from "../upgrades/registry/objects/ICTMRelease.sol";
import {LiveRoutingReader} from "../upgrades/registry/libraries/LiveRoutingReader.sol";
import {ReleaseFacetReader} from "../upgrades/registry/libraries/ReleaseFacetReader.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

/// @notice Test-only bootstrap engine: the production `BootstrapUpgradeZKsyncOS` facet reinstall
///         (remove the departing diamond's live routing, install the pinned release's facet set)
///         over the plain `DefaultUpgrade` L2 handling. The anvil registry harness pins it for its
///         bootstrap edge: the ZKsync OS engine's per-chain rewrite requires the real `L2V34Upgrade`
///         calldata shape, and the harness's delegate is a no-op stand-in.
contract BootstrapUpgradeDev is DefaultUpgrade {
    /// @notice The release whose facet set this edge installs.
    ICTMRelease public immutable GENESIS_RELEASE;

    constructor(ICTMRelease _genesisRelease) {
        if (address(_genesisRelease) == address(0)) {
            revert ZeroAddress();
        }
        GENESIS_RELEASE = _genesisRelease;
    }

    /// @inheritdoc DefaultUpgrade
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        _applyDerivedFacetCuts(LiveRoutingReader.removeAllCuts());
        _applyDerivedFacetCuts(ReleaseFacetReader.newChainInstallations(GENESIS_RELEASE));
        return super.upgrade(_proposedUpgrade);
    }
}
