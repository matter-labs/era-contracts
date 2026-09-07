// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";
import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {LiveRoutingReader} from "./registry/libraries/LiveRoutingReader.sol";
import {ReleaseFacetReader} from "./registry/libraries/ReleaseFacetReader.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title BootstrapUpgradeZKsyncOS
/// @notice The per-chain engine of the BOOTSTRAP edge — the one-time entry into the registry
///         model. The committed cut carries NO facet cuts: this init derives the full facet
///         reinstall on-chain and applies it before the storage/L2 part, the same two-step shape
///         `upgradeFromTransition` gives every registry-driven edge after it.
/// @dev The remove side is the DEPARTING diamond's own routing, read straight from its diamond
///      storage ({LiveRoutingReader}). The add side is the pinned genesis release's
///      facet set: the exact cuts a new chain geneses with (`ReleaseFacetReader`), so the
///      bootstrap edge cannot diverge from the genesis path — no hand-composed selector lists
///      anywhere in the committed calldata.
/// @dev The release is an IMMUTABLE, not a live `currentRelease` read: a laggard chain crossing
///      this edge after the CTM has moved on must still install the release this engine was
///      committed with. The bootstrap manifest's `upgradeCutInitCodehash` pin covers the
///      immutable, since it is part of this contract's deployed code.
contract BootstrapUpgradeZKsyncOS is DefaultUpgradeZKsyncOS {
    /// @notice The genesis release whose facet set this edge installs.
    ICTMRelease public immutable GENESIS_RELEASE;

    constructor(ICTMRelease _genesisRelease) {
        if (address(_genesisRelease) == address(0)) {
            revert ZeroAddress();
        }
        GENESIS_RELEASE = _genesisRelease;
    }

    /// @inheritdoc DefaultUpgradeZKsyncOS
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        // The reinstall FIRST, mirroring `Diamond.diamondCut`'s facets-then-init order that the
        // legacy committed cut relied on: the storage/L2 part below runs on the new facet set.
        _applyDerivedFacetCuts(LiveRoutingReader.removeAllCuts());
        _applyDerivedFacetCuts(ReleaseFacetReader.newChainInstallations(GENESIS_RELEASE));
        return super.upgrade(_proposedUpgrade);
    }
}
