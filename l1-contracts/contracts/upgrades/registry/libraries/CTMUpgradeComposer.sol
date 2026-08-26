// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {ICTMTransition, L2UpgradePlan} from "../objects/ICTMTransition.sol";
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

    /// @notice Builds the L1 -> L2 protocol upgrade transaction from the transition's L2 plan
    ///         (force-deployments, delegate target + calldata, factory dependencies).
    /// @dev The transaction calls `ComplexUpgrader.forceDeployAndUpgradeUniversal` (the universal
    ///      Era + ZKsyncOS path). Its nonce is derived from the new protocol version, as enforced
    ///      by `BaseZkSyncUpgrade._setL2SystemContractUpgrade`. A transaction is composed whenever
    ///      the plan has ANY L2 side — deployments or a delegate call; `L2ComplexUpgrader`
    ///      supports an empty deployment list followed by a delegatecall, and transition
    ///      initialization already rejects plans whose data could never execute.
    function buildL2UpgradeTx(ICTMTransition _transition) internal view returns (L2CanonicalTransaction memory) {
        uint256 newVersion = _transition.newProtocolVersion();
        L2UpgradePlan memory plan = _transition.l2Plan();
        if (plan.deployments.length == 0 && plan.delegateTo == address(0)) {
            // The upgrade has no L2 side (patch upgrades, or L1-only minor upgrades): an all-zero
            // transaction (txType == 0) makes `BaseZkSyncUpgrade` skip the L2 protocol upgrade
            // transaction entirely.
            return ProposedUpgradeLib.emptyL2CanonicalTransaction();
        }

        // VM identity is single-sourced from the target release's pinned DiamondInit.
        bool isZKsyncOS = IDiamondInit(ICTMRelease(_transition.newRelease()).diamondInit()).IS_ZKSYNC_OS();

        L2CanonicalTransaction memory transaction = ProposedUpgradeLib.emptyL2CanonicalTransaction();
        transaction.txType = isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = protocolUpgradeNonce(newVersion);
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (plan.deployments, plan.delegateTo, plan.delegateCalldata)
        );
        transaction.factoryDeps = plan.factoryDepHashes;
        return transaction;
    }

    /// @notice Builds the `ProposedUpgrade` embedded in the upgrade cut's init calldata.
    function buildProposedUpgrade(
        ICTMTransition _transition
    ) internal view returns (ProposedUpgrade memory proposedUpgrade) {
        uint256 newVersion = _transition.newProtocolVersion();
        proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newVersion);
        proposedUpgrade.l2ProtocolUpgradeTx = buildL2UpgradeTx(_transition);
        // Straight from the TARGET release, not from `CTM.currentRelease()`: a chain several
        // versions behind executes the transition that names its own next release, and the CTM may
        // already have moved past it.
        proposedUpgrade.verifier = ICTMRelease(_transition.newRelease()).verifier();
        (
            proposedUpgrade.bootloaderHash,
            proposedUpgrade.defaultAccountHash,
            proposedUpgrade.evmEmulatorHash
        ) = _transition.baseSystemContractHashChanges();
        proposedUpgrade.upgradeTimestamp = _transition.upgradeTimestamp();
    }

    /// @notice The nonce of the L2 protocol upgrade transaction for a packed SemVer version.
    /// @dev Mirrors `UpgradeHelperLib.getProtocolUpgradeNonce`: the packed version without its
    ///      patch component. `BaseZkSyncUpgrade` enforces this equals the new minor version.
    function protocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return _protocolVersion >> SEMVER_MINOR_OFFSET;
    }
}
