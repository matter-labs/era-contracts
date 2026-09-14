// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBootstrapUpgrade} from "./IBootstrapUpgrade.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IRegistryBootstrapMigration} from "./registry/bootstrap/IRegistryBootstrapMigration.sol";
import {CTMUpgradeComposer} from "./registry/libraries/CTMUpgradeComposer.sol";
import {LiveRoutingReader} from "./registry/libraries/LiveRoutingReader.sol";
import {ReleaseFacetReader} from "./registry/libraries/ReleaseFacetReader.sol";
import {BootstrapManifest} from "./registry/RegistryTypes.sol";
import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BootstrapEngineReleaseMismatch} from "./ZkSyncUpgradeErrors.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The bootstrap edge's entrypoint ({BootstrapUpgradeZKsyncOS} is the engine). The
///         committed cut carries NO facet cuts: this init derives the full facet reinstall on-chain
///         and applies it before the storage/L2 part, the same two-step shape
///         `upgradeFromTransition` gives every registry-driven edge after it. See the Bootstrap
///         section of {docs/registry-driven-upgrades.md}.
/// @dev The remove side is the DEPARTING diamond's own routing, read straight from its diamond
///      storage ({LiveRoutingReader}). The add side is the pinned genesis release's facet set: the
///      exact cuts a new chain geneses with (`ReleaseFacetReader`), so the bootstrap edge cannot
///      diverge from the genesis path — no hand-composed selector lists anywhere in the committed
///      calldata.
/// @dev The release is an IMMUTABLE, not a live `currentRelease` read: a laggard chain crossing
///      this edge after the CTM has moved on must still install the release this engine was
///      committed with. The bootstrap manifest's `upgradeEngine` pin covers the immutable, since it
///      is part of this contract's deployed code.
abstract contract BaseBootstrapUpgrade is BaseZkSyncUpgrade, IBootstrapUpgrade {
    /// @notice The genesis release whose facet set and verifier this edge installs.
    ICTMRelease public immutable GENESIS_RELEASE;

    constructor(ICTMRelease _genesisRelease) {
        if (address(_genesisRelease) == address(0)) {
            revert ZeroAddress();
        }
        GENESIS_RELEASE = _genesisRelease;
    }

    /// @inheritdoc IBootstrapUpgrade
    function upgradeFromBootstrap(address _migration) external returns (bytes32) {
        _requireAllBatchesExecuted();
        IRegistryBootstrapMigration migration = IRegistryBootstrapMigration(_migration);
        BootstrapManifest memory m = migration.getManifest();
        // The manifest pins the engine (whose code carries `GENESIS_RELEASE`) and the release it
        // installs on the CTM as two separate rows; refuse a pair that disagrees rather than put
        // one release's facets and verifier on chains the CTM records as running another.
        if (m.currentRelease.addr != address(GENESIS_RELEASE)) {
            revert BootstrapEngineReleaseMismatch(m.currentRelease.addr, address(GENESIS_RELEASE));
        }

        // The reinstall FIRST, mirroring `Diamond.diamondCut`'s facets-then-init order that the
        // legacy committed cut relied on: the storage/L2 part below runs on the new facet set.
        _applyDerivedFacetCuts(LiveRoutingReader.removeAllCuts());
        _applyDerivedFacetCuts(ReleaseFacetReader.newChainInstallations(GENESIS_RELEASE));
        _upgrade({
            _newProtocolVersion: m.newProtocolVersion,
            _upgradeTimestamp: m.upgradeTimestamp,
            _verifier: GENESIS_RELEASE.verifier(),
            _l2ProtocolUpgradeTx: CTMUpgradeComposer.buildL2UpgradeTxFromPlan({
                _plan: migration.l2Plan(),
                _newRelease: GENESIS_RELEASE,
                _newProtocolVersion: m.newProtocolVersion,
                _bridgehub: s.bridgehub,
                _chainId: s.chainId
            })
        });
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
