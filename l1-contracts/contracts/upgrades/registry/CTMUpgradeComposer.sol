// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreContract, CTMContract} from "./ContractIdentifiers.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {DiamondCutBuilder} from "../../state-transition/libraries/DiamondCutBuilder.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {ISelfDescribingFacet} from "../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {ChainCreationParams} from "../../state-transition/IChainTypeManager.sol";
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
///      `CoreContract`: L2 system-contract bytecodes are pinned per CTM (Era and ZKsyncOS ship
///      different sets). Ecosystem-wide (core) L1 upgrades have no composition to do beyond
///      proxy/impl lookups and live in `EcosystemUpgradeModule`.
/// @dev This library is the on-chain port of the composition logic that
///      `deploy-scripts/upgrade/default-upgrade/CTMUpgradeBase.sol` performs off-chain today.
///      Because both the upgrade cut (for existing chains) and the chain-creation cut (for new
///      chains) are derived from the same registry constants, they cannot drift apart.
library CTMUpgradeComposer {
    /// @dev The facet swaps of an upgrade together with the selector lists they diff.
    struct SwapSet {
        DiamondCutBuilder.FacetSwap[] swaps;
        bytes4[][] oldSelectors;
        bytes4[][] newSelectors;
    }

    /// @notice Builds the facet swaps taking a chain from the registry's old protocol version to
    ///         its new one. The registry's old-version facet rows ARE the plan: one swap per row,
    ///         no diffing heuristics — the generated data already says exactly what changes.
    /// @dev Per planned facet, the old address comes from the old-side row (zero = pure addition)
    ///      and the new address from the new-side facet set (absent = pure removal). Selector
    ///      lists come from the facets themselves (`ISelfDescribingFacet.selectors()`, immutable
    ///      bytecode, so recomposition stays stable across the upgrade window) unless the
    ///      registry pins a list for that facet version — the bootstrap override for facet
    ///      versions deployed before `ISelfDescribingFacet` existed. Never from live diamond
    ///      state.
    function buildFacetSwaps(ICTMRegistry _registry) internal view returns (SwapSet memory swapSet) {
        uint256 oldVersion = _registry.oldProtocolVersion();
        uint256 newVersion = _registry.newProtocolVersion();
        CTMContract[] memory plan = _registry.facetList(oldVersion);
        uint256 planLength = plan.length;

        swapSet.swaps = new DiamondCutBuilder.FacetSwap[](planLength);
        swapSet.oldSelectors = new bytes4[][](planLength);
        swapSet.newSelectors = new bytes4[][](planLength);
        for (uint256 i = 0; i < planLength; ++i) {
            CTMContract facet = plan[i];
            address oldAddress = _registry.ctmAddress(facet, oldVersion);
            address newAddress = _registry.ctmAddress(facet, newVersion);
            swapSet.swaps[i] = DiamondCutBuilder.FacetSwap({
                oldFacet: oldAddress,
                newFacet: newAddress,
                isFreezable: _registry.facetIsFreezable(facet)
            });
            swapSet.oldSelectors[i] = oldAddress == address(0)
                ? new bytes4[](0)
                : _facetSelectors(_registry, facet, oldVersion, oldAddress);
            swapSet.newSelectors[i] = newAddress == address(0)
                ? new bytes4[](0)
                : _facetSelectors(_registry, facet, newVersion, newAddress);
        }
    }

    /// @dev The selector list of a facet at a version: the registry's pinned list when one
    ///      exists (bootstrap override for facet versions predating `ISelfDescribingFacet`),
    ///      otherwise read from the facet's own immutable bytecode.
    function _facetSelectors(
        ICTMRegistry _registry,
        CTMContract _facet,
        uint256 _protocolVersion,
        address _facetAddress
    ) private view returns (bytes4[] memory selectorList) {
        selectorList = _registry.facetSelectors(_facet, _protocolVersion);
        if (selectorList.length == 0) {
            selectorList = ISelfDescribingFacet(_facetAddress).selectors();
        }
    }

    /// @notice Builds the diamond cut that upgrades an existing chain, with the given init
    ///         delegatecall (typically `DefaultUpgrade.upgrade(proposedUpgrade)`).
    function buildUpgradeCutData(
        ICTMRegistry _registry,
        address _initAddress,
        bytes memory _initCalldata
    ) internal view returns (Diamond.DiamondCutData memory) {
        SwapSet memory swapSet = buildFacetSwaps(_registry);
        return
            Diamond.DiamondCutData({
                facetCuts: DiamondCutBuilder.buildCuts(swapSet.swaps, swapSet.oldSelectors, swapSet.newSelectors),
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

    /// @dev The initial cut of a new chain: a pure addition of the new facet set, initialized
    ///      through `DiamondInit` with the registry-pinned init calldata.
    function _buildChainCreationCut(
        ICTMRegistry _registry,
        uint256 _newVersion
    ) private view returns (Diamond.DiamondCutData memory) {
        CTMContract[] memory facets = _registry.facetList(_newVersion);
        uint256 facetsLength = facets.length;
        DiamondCutBuilder.FacetSwap[] memory swaps = new DiamondCutBuilder.FacetSwap[](facetsLength);
        bytes4[][] memory oldSelectors = new bytes4[][](facetsLength);
        bytes4[][] memory newSelectors = new bytes4[][](facetsLength);
        for (uint256 i = 0; i < facetsLength; ++i) {
            swaps[i] = DiamondCutBuilder.FacetSwap({
                oldFacet: address(0),
                newFacet: _registry.ctmAddress(facets[i], _newVersion),
                isFreezable: _registry.facetIsFreezable(facets[i])
            });
            oldSelectors[i] = new bytes4[](0);
            newSelectors[i] = _facetSelectors(
                _registry,
                facets[i],
                _newVersion,
                _registry.ctmAddress(facets[i], _newVersion)
            );
        }

        return
            Diamond.DiamondCutData({
                facetCuts: DiamondCutBuilder.buildCuts(swaps, oldSelectors, newSelectors),
                initAddress: _registry.ctmAddress(CTMContract.DiamondInit, _newVersion),
                initCalldata: _registry.chainCreationInitCalldata(_newVersion)
            });
    }

    /// @notice The nonce of the L2 protocol upgrade transaction for a packed SemVer version.
    /// @dev Mirrors `UpgradeHelperLib.getProtocolUpgradeNonce`: the packed version without its
    ///      patch component. `BaseZkSyncUpgrade` enforces this equals the new minor version.
    function protocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return _protocolVersion >> SEMVER_MINOR_OFFSET;
    }
}
