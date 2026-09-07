// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IL2DelegateCalldataComposer} from "../objects/IL2DelegateCalldataComposer.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "../../../state-transition/l2-deps/IComplexUpgrader.sol";
import {IDiamondInit} from "../../../state-transition/chain-interfaces/IDiamondInit.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "../../../state-transition/libraries/ProposedUpgradeLib.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "../../../common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "../../../common/libraries/SemVer.sol";
import {L2UpgradePlan, TransitionManifest} from "../RegistryTypes.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Composes the CTM-scoped payloads of a protocol upgrade — the diamond cut that names the
///         transition, the `ProposedUpgrade`, and the L2 protocol upgrade transaction — from a
///         pinned transition's constants, at execution time, on-chain. Facet changes are NOT
///         composed here: they are derived at transition initialization and applied verbatim from
///         `transition.facetCuts()`. New-chain genesis data comes from the release the CTM pins,
///         not from a composed `ChainCreationParams`.
/// @dev Everything here is CTM-scoped, including the L2 force-deployments keyed by
///      `L2EcosystemContract`: L2 system-contract bytecodes are pinned per CTM (Era and ZKsyncOS ship
///      different sets). Ecosystem-wide (core) L1 upgrades have no composition to do beyond
///      proxy/impl lookups and live in `EcosystemUpgradeExecutor`.
/// @dev This library is the on-chain port of the composition logic that
///      `deploy-scripts/upgrade/default-upgrade/CTMUpgradeBase.sol` performs off-chain today.
///      Because the upgrade path (existing chains) and the genesis path (new chains) both resolve
///      to the same pinned release, they cannot drift apart.
library CTMUpgradeComposer {
    /// @notice Builds the diamond cut that upgrades an existing chain: no `facetCuts` of its own.
    ///         The committed cut names the write-once transition; `BaseZkSyncUpgrade` reads the
    ///         derived facet cuts (`transition.facetCuts()`) straight from that same transition
    ///         at execution time, so the swaps are never carried in the cut and both facet changes
    ///         and proposal composition share one source of truth.
    function buildUpgradeCutData(
        address _initAddress,
        bytes memory _initCalldata
    ) internal pure returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: _initAddress,
                initCalldata: _initCalldata
            });
    }

    /// @notice The L1 -> L2 protocol upgrade transaction a transition composes for the ecosystem
    ///         whose Bridgehub is `_bridgehub` (see {buildL2UpgradeTxFromPlan}).
    function buildL2UpgradeTx(
        ICTMTransition _transition,
        address _bridgehub
    ) internal view returns (L2CanonicalTransaction memory) {
        TransitionManifest memory m = _transition.getManifest();
        return
            buildL2UpgradeTxFromPlan({
                _plan: _transition.l2Plan(),
                _newRelease: ICTMRelease(m.newRelease),
                _newProtocolVersion: m.newProtocolVersion,
                _bridgehub: _bridgehub
            });
    }

    /// @notice The L1 -> L2 protocol upgrade transaction for a FINAL L2 plan: the force
    ///         deployments, the delegate call the `L2ComplexUpgrader` performs after them (its
    ///         calldata defined by the plan's pinned composer from `_newRelease` and `_bridgehub`)
    ///         and the factory dependencies. Shared by transitions and the bootstrap edge, so both
    ///         compose the same transaction from the same inputs.
    function buildL2UpgradeTxFromPlan(
        L2UpgradePlan memory _plan,
        ICTMRelease _newRelease,
        uint256 _newProtocolVersion,
        address _bridgehub
    ) internal view returns (L2CanonicalTransaction memory) {
        if (_plan.deployments.length == 0 && _plan.delegateTo == address(0)) {
            // No L2 side (patch upgrades, or L1-only minor upgrades): an all-zero transaction
            // (txType == 0) makes `BaseZkSyncUpgrade` skip the L2 protocol upgrade transaction.
            return ProposedUpgradeLib.emptyL2CanonicalTransaction();
        }
        // VM identity is single-sourced from the target release's pinned DiamondInit.
        bool isZKsyncOS = IDiamondInit(_newRelease.diamondInit()).IS_ZKSYNC_OS();
        L2CanonicalTransaction memory transaction = ProposedUpgradeLib.emptyL2CanonicalTransaction();
        transaction.txType = isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = protocolUpgradeNonce(_newProtocolVersion);
        // What the delegate is called WITH is defined by the pinned version-specific composer
        // from authoritative inputs — never by authored bytes (see {IL2DelegateCalldataComposer}).
        bytes memory delegateCalldata = _plan.delegateComposer == address(0)
            ? bytes("")
            : IL2DelegateCalldataComposer(_plan.delegateComposer).composeDelegateCalldata(_newRelease, _bridgehub);
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_plan.deployments, _plan.delegateTo, delegateCalldata)
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
        return transaction;
    }

    /// @notice Builds the `ProposedUpgrade` embedded in a transition's upgrade cut init calldata.
    function buildProposedUpgrade(
        ICTMTransition _transition,
        address _bridgehub
    ) internal view returns (ProposedUpgrade memory) {
        TransitionManifest memory m = _transition.getManifest();
        // Straight from the TARGET release, not from `CTM.currentRelease()`: a chain several
        // versions behind executes the transition that names its own next release, and the CTM may
        // already have moved past it.
        return
            buildProposedUpgradeFromPlan({
                _plan: _transition.l2Plan(),
                _newRelease: ICTMRelease(m.newRelease),
                _newProtocolVersion: m.newProtocolVersion,
                _upgradeTimestamp: m.upgradeTimestamp,
                _bridgehub: _bridgehub
            });
    }

    /// @notice The `ProposedUpgrade` for a final L2 plan and its target release: the composed L2
    ///         transaction, the release's verifier and the schedule. The frozen struct's EraVM
    ///         bytecode-hash words stay zero (`BaseZkSyncUpgrade` no longer reads them).
    function buildProposedUpgradeFromPlan(
        L2UpgradePlan memory _plan,
        ICTMRelease _newRelease,
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _bridgehub
    ) internal view returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(_newProtocolVersion);
        proposedUpgrade.l2ProtocolUpgradeTx = buildL2UpgradeTxFromPlan({
            _plan: _plan,
            _newRelease: _newRelease,
            _newProtocolVersion: _newProtocolVersion,
            _bridgehub: _bridgehub
        });
        proposedUpgrade.verifier = _newRelease.verifier();
        proposedUpgrade.upgradeTimestamp = _upgradeTimestamp;
    }

    /// @notice The nonce of the L2 protocol upgrade transaction for a packed SemVer version.
    /// @dev Mirrors `UpgradeHelperLib.getProtocolUpgradeNonce`: the packed version without its
    ///      patch component. `BaseZkSyncUpgrade` enforces this equals the new minor version.
    function protocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return _protocolVersion >> SEMVER_MINOR_OFFSET;
    }
}
