// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";
import {ICTMTransition, L2Deployment} from "./ICTMTransition.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "../../state-transition/libraries/ProposedUpgradeLib.sol";
import {L2CanonicalTransaction} from "../../common/Messaging.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "../../common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "../../common/libraries/SemVer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Composes every CTM-scoped payload of a protocol upgrade — facet swaps, diamond
///         cuts, `ChainCreationParams` and the L2 protocol upgrade transaction — from a per-CTM
///         registry's pinned constants, at execution time, on-chain.
/// @dev Everything here is CTM-scoped, including the L2 force-deployments keyed by
///      `L2EcosystemContract`: L2 system-contract bytecodes are pinned per CTM (Era and ZKsyncOS ship
///      different sets). Ecosystem-wide (core) L1 upgrades have no composition to do beyond
///      proxy/impl lookups and live in `EcosystemUpgradeModule`.
/// @dev This library is the on-chain port of the composition logic that
///      `deploy-scripts/upgrade/default-upgrade/CTMUpgradeBase.sol` performs off-chain today.
///      Because both the upgrade cut (for existing chains) and the chain-creation cut (for new
///      chains) are derived from the same registry constants, they cannot drift apart.
library CTMUpgradeComposer {
    /// @dev The facet swaps of an upgrade together with the selector lists they diff.
    /// @notice Builds the facet-swap plan taking a chain from the registry's old protocol version
    ///         to its new one. The registry's old-version facet rows ARE the plan: one swap per
    ///         row, no diffing heuristics — the generated data already says exactly what changes.
    /// @notice Builds the diamond cut that upgrades an existing chain: no `facetCuts` of its own.
    ///         The facet-swap plan is read straight from the registry by `BaseZkSyncUpgrade` at
    ///         execution time (via the `upgradeRegistryForVersion` pointer the CTM stores) — it is
    ///         not carried in the cut.
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

    /// @notice Builds the L1 -> L2 protocol upgrade transaction from the registry's pinned
    ///         force-deployments, delegate target and factory dependencies.
    /// @dev The transaction calls `ComplexUpgrader.forceDeployAndUpgradeUniversal` (the universal
    ///      Era + ZKsyncOS path). Its nonce is derived from the new protocol version, as enforced
    ///      by `BaseZkSyncUpgrade._setL2SystemContractUpgrade`.
    function buildL2UpgradeTx(ICTMTransition _transition) internal view returns (L2CanonicalTransaction memory) {
        ICTMRelease release = ICTMRelease(_transition.newRelease());
        uint256 newVersion = _transition.newProtocolVersion();
        L2Deployment[] memory deploymentRows = _transition.l2Deployments();
        uint256 deployListLength = deploymentRows.length;
        if (deployListLength == 0) {
            // The upgrade has no L2 side (patch upgrades, or L1-only minor upgrades): an all-zero
            // transaction (txType == 0) makes `BaseZkSyncUpgrade` skip the L2 protocol upgrade
            // transaction entirely.
            return ProposedUpgradeLib.emptyL2CanonicalTransaction();
        }
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](deployListLength);
        for (uint256 i = 0; i < deployListLength; ++i) {
            deployments[i] = deploymentRows[i].info;
        }

        (address delegateTo, bytes memory delegateCalldata) = _transition.l2UpgradeDelegate();

        L2CanonicalTransaction memory transaction = ProposedUpgradeLib.emptyL2CanonicalTransaction();
        transaction.txType = release.isZKsyncOS() ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = protocolUpgradeNonce(newVersion);
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (deployments, delegateTo, delegateCalldata)
        );
        transaction.factoryDeps = _transition.factoryDepHashes();
        return transaction;
    }

    /// @notice Builds the `ProposedUpgrade` embedded in the upgrade cut's init calldata.
    function buildProposedUpgrade(
        ICTMTransition _transition
    ) internal view returns (ProposedUpgrade memory proposedUpgrade) {
        uint256 newVersion = _transition.newProtocolVersion();
        proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newVersion);
        proposedUpgrade.l2ProtocolUpgradeTx = buildL2UpgradeTx(_transition);
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
