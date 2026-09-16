// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IL2DelegateCalldataComposer} from "../objects/IL2DelegateCalldataComposer.sol";
import {IRegistryBootstrapMigration} from "../bootstrap/IRegistryBootstrapMigration.sol";
import {IDefaultUpgrade} from "../../IDefaultUpgrade.sol";
import {IBootstrapUpgrade} from "../../IBootstrapUpgrade.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "../../../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2CanonicalTransactionLib} from "../../../state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {L2UpgradePlan, TransitionManifest} from "../RegistryTypes.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Composes the CTM-scoped payloads of a protocol upgrade — the diamond cut that names the
///         pinned object and the L2 protocol upgrade transaction — from that object's constants, at
///         execution time, on-chain. Facet changes are NOT composed here: they are derived at
///         transition initialization and applied verbatim from `transition.facetCuts()`. New-chain
///         genesis data comes from the release the CTM pins, not from a composed
///         `ChainCreationParams`.
/// @dev Everything here is CTM-scoped, including the L2 force-deployments keyed by
///      `L2EcosystemContract`: L2 system-contract bytecodes are pinned per CTM. The registry
///      composes for ZKsync OS chains only. Ecosystem-wide (core) L1 upgrades have no composition
///      to do beyond proxy/impl lookups and live in `EcosystemUpgradeExecutor`.
/// @dev Because the upgrade path (existing chains) and the genesis path (new chains) both resolve
///      to the same pinned release, they cannot drift apart.
library CTMUpgradeComposer {
    /// @notice Builds the diamond cut that upgrades an existing chain across `_transition`: no
    ///         `facetCuts` of its own, the transition's engine as the init target and
    ///         `upgradeFromTransition(transition)` as its calldata. Both are determined by the
    ///         transition, so nothing else is accepted: the engine reads the facet cuts and every
    ///         other input straight from the same object at execution time, and facet changes and
    ///         payload composition share one source of truth.
    function buildUpgradeCutData(ICTMTransition _transition) internal view returns (Diamond.DiamondCutData memory) {
        return
            _cutNamingObject(
                _transition.upgradeEngine(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }

    /// @notice The bootstrap edge's cut (see {buildUpgradeCutData}): the migration's engine
    ///         as the init target and `upgradeFromBootstrap(migration)` as its calldata.
    function buildBootstrapUpgradeCutData(
        IRegistryBootstrapMigration _migration
    ) internal view returns (Diamond.DiamondCutData memory) {
        return
            _cutNamingObject(
                _migration.getManifest().upgradeEngine,
                abi.encodeCall(IBootstrapUpgrade.upgradeFromBootstrap, (address(_migration)))
            );
    }

    /// @notice The composed transaction of a transition for one chain (see {buildL2UpgradeTxFromPlan}).
    /// @dev For callers holding only the transition address; an executing engine already holds the
    ///      manifest and enters at {buildL2UpgradeTxFromPlan} to avoid decoding it twice.
    function buildL2UpgradeTx(
        ICTMTransition _transition,
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (L2CanonicalTransaction memory) {
        TransitionManifest memory m = _transition.getManifest();
        return
            buildL2UpgradeTxFromPlan({
                _plan: _transition.l2Plan(),
                _newRelease: ICTMRelease(m.newRelease),
                _newProtocolVersion: m.newProtocolVersion,
                _bridgehub: _bridgehub,
                _chainId: _chainId
            });
    }

    /// @notice The FINAL L1 -> L2 protocol upgrade transaction of a chain for a FINAL L2 plan: the
    ///         force deployments, the delegate call the `L2ComplexUpgrader` performs after them (its
    ///         calldata defined by the plan's composer from `_newRelease`, `_bridgehub` and
    ///         `_chainId`) and the factory dependencies. Every caller reaches this one function, so
    ///         the transition path and the bootstrap edge compose the same transaction from the
    ///         same inputs; the bootstrap has a plan and a release but no transition object to
    ///         unpack. The engine commits the result as is: there is no later per-chain rewrite.
    function buildL2UpgradeTxFromPlan(
        L2UpgradePlan memory _plan,
        ICTMRelease _newRelease,
        uint256 _newProtocolVersion,
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (L2CanonicalTransaction memory) {
        if (_plan.deployments.length == 0 && _plan.delegateTo == address(0)) {
            // No L2 side (patch upgrades, or L1-only minor upgrades): an all-zero transaction
            // (txType == 0) makes `BaseZkSyncUpgrade` skip the L2 protocol upgrade transaction.
            return L2CanonicalTransactionLib.emptyL2CanonicalTransaction();
        }
        // What the delegate is called WITH is defined by the version-specific composer
        // from authoritative inputs — never by authored bytes (see {IL2DelegateCalldataComposer}).
        bytes memory delegateCalldata = _plan.delegateComposer == address(0)
            ? bytes("")
            : IL2DelegateCalldataComposer(_plan.delegateComposer).composeDelegateCalldata(
                _newRelease,
                _bridgehub,
                _chainId
            );
        L2CanonicalTransaction memory transaction = L2CanonicalTransactionLib.upgradeTransaction(
            _newProtocolVersion,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (_plan.deployments, _plan.delegateTo, delegateCalldata)
            )
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
        return transaction;
    }

    /// @dev The one cut shape the registry commits: no facet cuts, an engine init that names the
    ///      write-once object the engine reads everything else from.
    function _cutNamingObject(
        address _engine,
        bytes memory _initCalldata
    ) private pure returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: _engine,
                initCalldata: _initCalldata
            });
    }
}
