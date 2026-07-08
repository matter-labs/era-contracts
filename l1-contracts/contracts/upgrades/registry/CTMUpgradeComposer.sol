// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreContract, CTMContract} from "./ContractIdentifiers.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {FacetInstallation, InitializeDataNewChain} from "../../state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams} from "../../state-transition/IChainTypeManager.sol";
import {
    ProposedUpgrade,
    ProposedUpgradeLib,
    UpgradeFacetSwap
} from "../../state-transition/libraries/ProposedUpgradeLib.sol";
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
///      `CoreContract`: L2 system-contract bytecodes are pinned per CTM (Era and ZKsyncOS ship
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
    /// @dev Per planned facet, the old address comes from the old-side row (zero = pure addition)
    ///      and the new address from the new-side facet set (absent = pure removal). Selector
    ///      lists are copied verbatim from the registry — empty (the steady state) defers to the
    ///      facet's own `ISelfDescribingFacet.selectors()` at execution time inside
    ///      `BaseZkSyncUpgrade._upgradeFacets`; a pinned list is the bootstrap override for facet
    ///      versions deployed before that interface existed. Nothing here reads facet or diamond
    ///      state, so the committed calldata stays small and recomposition is trivially stable.
    function buildFacetSwapPlan(ICTMRegistry _registry) internal view returns (UpgradeFacetSwap[] memory plan) {
        uint256 oldVersion = _registry.oldProtocolVersion();
        uint256 newVersion = _registry.newProtocolVersion();
        CTMContract[] memory planFacets = _registry.facetList(oldVersion);
        uint256 planLength = planFacets.length;

        plan = new UpgradeFacetSwap[](planLength);
        for (uint256 i = 0; i < planLength; ++i) {
            CTMContract facet = planFacets[i];
            address oldAddress = _registry.ctmAddress(facet, oldVersion);
            address newAddress = _registry.ctmAddress(facet, newVersion);
            plan[i] = UpgradeFacetSwap({
                oldFacet: oldAddress,
                newFacet: newAddress,
                isFreezable: _registry.facetIsFreezable(facet),
                oldSelectors: oldAddress == address(0) ? new bytes4[](0) : _registry.facetSelectors(facet, oldVersion),
                newSelectors: newAddress == address(0) ? new bytes4[](0) : _registry.facetSelectors(facet, newVersion)
            });
        }
    }

    /// @notice Builds the diamond cut that upgrades an existing chain: no `facetCuts` of its own —
    ///         facet swaps ride inside the init calldata's `ProposedUpgrade.facetSwaps` and are
    ///         applied by `BaseZkSyncUpgrade` itself, inside the diamond's context.
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
    function buildL2UpgradeTx(ICTMRegistry _registry) internal view returns (L2CanonicalTransaction memory) {
        uint256 newVersion = _registry.newProtocolVersion();

        CoreContract[] memory deployList = _registry.l2ForceDeployList(newVersion);
        uint256 deployListLength = deployList.length;
        if (deployListLength == 0) {
            // The upgrade has no L2 side (patch upgrades, or L1-only minor upgrades): an all-zero
            // transaction (txType == 0) makes `BaseZkSyncUpgrade` skip the L2 protocol upgrade
            // transaction entirely.
            return ProposedUpgradeLib.emptyL2CanonicalTransaction();
        }
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](deployListLength);
        for (uint256 i = 0; i < deployListLength; ++i) {
            deployments[i] = _registry.l2ForceDeployment(deployList[i], newVersion);
        }

        (address delegateTo, bytes memory delegateCalldata) = _registry.l2UpgradeDelegate(newVersion);

        L2CanonicalTransaction memory transaction = ProposedUpgradeLib.emptyL2CanonicalTransaction();
        transaction.txType = _registry.isZKsyncOS() ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = protocolUpgradeNonce(newVersion);
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (deployments, delegateTo, delegateCalldata)
        );
        transaction.factoryDeps = _registry.factoryDepHashes(newVersion);
        return transaction;
    }

    /// @notice Builds the `ProposedUpgrade` embedded in the upgrade cut's init calldata.
    function buildProposedUpgrade(
        ICTMRegistry _registry,
        uint256 _upgradeTimestamp
    ) internal view returns (ProposedUpgrade memory proposedUpgrade) {
        uint256 newVersion = _registry.newProtocolVersion();
        proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newVersion);
        proposedUpgrade.l2ProtocolUpgradeTx = buildL2UpgradeTx(_registry);
        (
            proposedUpgrade.bootloaderHash,
            proposedUpgrade.defaultAccountHash,
            proposedUpgrade.evmEmulatorHash
        ) = _registry.baseSystemContractHashes(newVersion);
        proposedUpgrade.upgradeTimestamp = _upgradeTimestamp;
        proposedUpgrade.facetSwaps = buildFacetSwapPlan(_registry);
    }

    /// @notice Builds the `ChainCreationParams` for chains created at the registry's new protocol
    ///         version. The chain-creation diamond cut installs the same facet set the upgrade cut
    ///         produces on existing chains — both derive from the same registry constants, so they
    ///         cannot disagree.
    function buildChainCreationParams(ICTMRegistry _registry) internal view returns (ChainCreationParams memory) {
        uint256 newVersion = _registry.newProtocolVersion();
        (
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        ) = _registry.genesisParams(newVersion);

        return
            ChainCreationParams({
                genesisUpgrade: genesisUpgrade,
                genesisBatchHash: genesisBatchHash,
                genesisIndexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
                genesisBatchCommitment: genesisBatchCommitment,
                diamondCut: _buildChainCreationCut(_registry, newVersion),
                forceDeploymentsData: _registry.fixedForceDeploymentsData(newVersion)
            });
    }

    /// @dev The initial cut of a new chain: no `facetCuts` — `DiamondInit` installs the new
    ///      facet set itself from the `FacetInstallation` list in its init calldata, composed
    ///      here from the same registry rows the upgrade path uses (no drift by construction).
    ///      Selector lists ride along only when the registry pins them (bootstrap override);
    ///      empty means DiamondInit reads the facet's own `selectors()` at execution time.
    function _buildChainCreationCut(
        ICTMRegistry _registry,
        uint256 _newVersion
    ) private view returns (Diamond.DiamondCutData memory) {
        CTMContract[] memory facets = _registry.facetList(_newVersion);
        uint256 facetsLength = facets.length;
        FacetInstallation[] memory installations = new FacetInstallation[](facetsLength);
        for (uint256 i = 0; i < facetsLength; ++i) {
            installations[i] = FacetInstallation({
                facet: _registry.ctmAddress(facets[i], _newVersion),
                isFreezable: _registry.facetIsFreezable(facets[i]),
                selectors: _registry.facetSelectors(facets[i], _newVersion)
            });
        }
        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = _registry
            .baseSystemContractHashes(_newVersion);

        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: _registry.ctmAddress(CTMContract.DiamondInit, _newVersion),
                initCalldata: abi.encode(
                    InitializeDataNewChain({
                        l2BootloaderBytecodeHash: bootloaderHash,
                        l2DefaultAccountBytecodeHash: defaultAccountHash,
                        l2EvmEmulatorBytecodeHash: evmEmulatorHash,
                        facets: installations
                    })
                )
            });
    }

    /// @notice The nonce of the L2 protocol upgrade transaction for a packed SemVer version.
    /// @dev Mirrors `UpgradeHelperLib.getProtocolUpgradeNonce`: the packed version without its
    ///      patch component. `BaseZkSyncUpgrade` enforces this equals the new minor version.
    function protocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return _protocolVersion >> SEMVER_MINOR_OFFSET;
    }
}
