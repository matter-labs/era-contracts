// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DefaultUpgrade} from "./DefaultUpgrade.sol";
import {IBootstrapUpgrade} from "./IBootstrapUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IRegistryBootstrapMigration} from "./registry/bootstrap/IRegistryBootstrapMigration.sol";
import {LiveRoutingReader} from "./registry/libraries/LiveRoutingReader.sol";
import {ReleaseFacetReader} from "./registry/libraries/ReleaseFacetReader.sol";
import {Diamond} from "../state-transition/libraries/Diamond.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The bootstrap edge's engine: the facet reinstall that carries a pre-registry chain into
///         the registry model, over the storage/L2 part and the transition entrypoint of
///         {DefaultUpgrade}, so the same deployment serves the one-time edge and any later
///         transition. See the Bootstrap section of {docs/registry-driven-upgrades.md}.
/// @dev The committed cut carries NO facet cuts: this init derives the full facet reinstall
///      on-chain and applies it before the storage/L2 part, the same two-step shape
///      `upgradeFromTransition` gives every registry-driven edge after it.
/// @dev The remove side is the DEPARTING diamond's own routing, read straight from its diamond
///      storage ({LiveRoutingReader}). The add side is the genesis release's facet set: the
///      exact cuts a new chain geneses with ({ReleaseFacetReader}), so the bootstrap edge cannot
///      diverge from the genesis path — no hand-composed selector lists anywhere in the committed
///      calldata.
contract BootstrapUpgrade is DefaultUpgrade, IBootstrapUpgrade {
    /// @inheritdoc IBootstrapUpgrade
    function upgradeFromBootstrap(address _migration) external returns (bytes32) {
        _requireAllBatchesExecuted();
        IRegistryBootstrapMigration migration = IRegistryBootstrapMigration(_migration);
        // The release the reinstall installs is the one the COMMITTED migration names, not the
        // CTM's live `currentRelease()`: a chain crossing this edge after the CTM has moved on
        // still lands on the release its own cut was committed with.
        (, , address genesisRelease) = migration.upgradeTarget();

        // The reinstall FIRST, mirroring `Diamond.diamondCut`'s facets-then-init order that the
        // legacy committed cut relied on: the storage/L2 part below runs on the new facet set.
        _applyDerivedFacetCuts(LiveRoutingReader.removeAllCuts());
        _applyDerivedFacetCuts(ReleaseFacetReader.newChainInstallations(ICTMRelease(genesisRelease)));
        _upgradeFromCommittedObject(migration);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
