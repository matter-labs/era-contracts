// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {RegistryDuplicateSelector} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet} from "../RegistryTypes.sol";
import {ISelfDescribingFacet} from "../../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {IComplexUpgrader} from "../../../state-transition/l2-deps/IComplexUpgrader.sol";
import {IDiamondInit} from "../../../state-transition/chain-interfaces/IDiamondInit.sol";
import {L2EcosystemContract} from "./ContractIdentifiers.sol";
import {L2InventoryLib} from "./L2InventoryLib.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice DERIVES a transition's final diamond cuts and L2 force deployments from its
///         `(fromRelease, newRelease)` pair. The delta is a pure function
///         of the two releases — it is computed once at transition initialization and stored as
///         ready-to-execute data, never hand-authored and never re-diffed at execution, so the
///         transition path (existing chains) cannot diverge from the release path (new chains)
///         by construction, and the chain applies the stored delta verbatim.
///
/// @dev Scope: L1 diamond routing and the table-driven L2 force deployments. The rest of the L2 payload (delegate target + calldata, factory deps) is
///      reviewed-and-pinned data — L1 cannot verify L2 execution effects, and the guarantee is
///      deliberately not overstated.
library TransitionDerivationLib {
    /// @dev One facet row with its routing read from the facet's own self-description
    ///      (see {GenesisFacet} — routing is not stored in the manifest).
    struct FacetRouting {
        address facet;
        bool isFreezable;
        bytes4[] selectors;
    }

    /// @notice Derives the diamond cuts whose execution transforms `_fromRelease`'s routing into
    ///         `_newRelease`'s routing.
    /// @dev A FULL REINSTALL, removals first: one `Remove` cut per departing facet (its complete
    ///      self-described routing, facet address zero per `Diamond._removeFunctions`) followed by
    ///      one `Add` cut per arriving facet. There is deliberately no selector-level diffing:
    ///      each release redeploys its facets, so a "minimal" delta re-routes almost everything
    ///      anyway — the diff engine bought little and cost a routing model.
    /// @dev Two shortcuts to an EMPTY cut, both by value rather than by release identity: the same
    ///      release on both edges, and two releases whose routing is byte-identical. The latter is
    ///      what a release change that touches no facet — a verifier replacement, say — costs a
    ///      chain: nothing. Without it, replacing one non-facet member of the snapshot would
    ///      remove and re-add every selector to the very same facets.
    function deriveFacetCuts(
        ICTMRelease _fromRelease,
        ICTMRelease _newRelease
    ) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        if (address(_fromRelease) == address(_newRelease)) {
            return facetCuts;
        }
        FacetRouting[] memory fromFacets = _loadRouting(_fromRelease);
        FacetRouting[] memory newFacets = _loadRouting(_newRelease);
        // Order-sensitive on purpose: the slot order is canonical ({GenesisManifestLib}), so equal
        // routing encodes equally, and a reordered-but-equivalent pair simply falls through to the
        // reinstall it would have got anyway.
        if (keccak256(abi.encode(fromFacets)) == keccak256(abi.encode(newFacets))) {
            return facetCuts;
        }
        // Pre-commit guards: a duplicated selector (or, downstream, an empty cut) would only
        // surface when chains execute — AFTER `applyCTMUpgrade` bumped the CTM version, stranding
        // every chain on an unexecutable transition. Facets with empty routing simply contribute
        // no cut (`Diamond` rejects empty selector lists).
        _requireNoDuplicateSelectors(fromFacets);
        _requireNoDuplicateSelectors(newFacets);

        uint256 fromFacetsLength = fromFacets.length;
        uint256 newFacetsLength = newFacets.length;
        uint256 cutCount = 0;
        for (uint256 i = 0; i < fromFacetsLength; ++i) {
            if (fromFacets[i].selectors.length != 0) {
                ++cutCount;
            }
        }
        for (uint256 i = 0; i < newFacetsLength; ++i) {
            if (newFacets[i].selectors.length != 0) {
                ++cutCount;
            }
        }

        facetCuts = new Diamond.FacetCut[](cutCount);
        uint256 cursor = 0;
        for (uint256 i = 0; i < fromFacetsLength; ++i) {
            if (fromFacets[i].selectors.length != 0) {
                facetCuts[cursor] = Diamond.FacetCut({
                    facet: address(0),
                    action: Diamond.Action.Remove,
                    isFreezable: false,
                    selectors: fromFacets[i].selectors
                });
                ++cursor;
            }
        }
        for (uint256 i = 0; i < newFacetsLength; ++i) {
            if (newFacets[i].selectors.length != 0) {
                facetCuts[cursor] = Diamond.FacetCut({
                    facet: newFacets[i].facet,
                    action: Diamond.Action.Add,
                    isFreezable: newFacets[i].isFreezable,
                    selectors: newFacets[i].selectors
                });
                ++cursor;
            }
        }
    }

    /// @notice Derives the transition's L2 force deployments from the RELEASE PAIR: every row of
    ///         the target release's L2 bytecode table whose descriptor differs from the departing
    ///         release's (a member new to the set counts as changed) becomes one force deployment
    ///         of that descriptor at its member's fixed address ({L2InventoryLib}).
    /// @dev Same philosophy as {deriveFacetCuts}: the delta is derived from the pair, never
    ///      authored, and members whose bytecode did not change are not touched — a facet-only or
    ///      verifier-only upgrade derives an empty L2 set. A same-release pair derives an empty
    ///      list by identity. The bootstrap edge has no departing release and
    ///      installs the target table in full ({deriveL2DeploymentsFromTable}). VM identity is
    ///      single-sourced from the target release's pinned DiamondInit, exactly like the L2
    ///      transaction composition.
    function deriveL2Deployments(
        ICTMRelease _fromRelease,
        ICTMRelease _newRelease
    ) internal view returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        if (address(_fromRelease) == address(_newRelease)) {
            return deployments;
        }
        bool isZKsyncOS = IDiamondInit(_newRelease.diamondInit()).IS_ZKSYNC_OS();
        return
            deriveL2DeploymentsFromTable(
                changedL2Rows(_fromRelease.l2BytecodeInfos(), _newRelease.l2BytecodeInfos()),
                isZKsyncOS
            );
    }

    /// @notice The rows of `_newTable` that differ from `_fromTable` at the same member index, every
    ///         other slot empty. The enum is append-only, so a departing release built against a
    ///         shorter enum simply has no row to compare for the appended members.
    function changedL2Rows(
        bytes[] memory _fromTable,
        bytes[] memory _newTable
    ) internal pure returns (bytes[] memory changed) {
        uint256 length = _newTable.length;
        changed = new bytes[](length);
        uint256 fromLength = _fromTable.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_newTable[i].length == 0) {
                continue;
            }
            if (i >= fromLength || keccak256(_fromTable[i]) != keccak256(_newTable[i])) {
                changed[i] = _newTable[i];
            }
        }
    }

    /// @notice The table form of {deriveL2Deployments}, shared with the deploy tooling so the
    ///         script-composed bootstrap L2 leg and the on-chain transition path derive from the
    ///         same function.
    /// @dev Era rows embed a full `ForceDeployment` (see {IComplexUpgrader}); ZKsync OS rows are
    ///      uniformly system-proxy upgrades — the only Unsafe deployment an upgrade carries is
    ///      the version-specific delegate, which is pinned transition data, never table-derived.
    function deriveL2DeploymentsFromTable(
        bytes[] memory _l2BytecodeInfos,
        bool _isZKsyncOS
    ) internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        uint256 length = _l2BytecodeInfos.length;
        uint256 count = 0;
        for (uint256 i = 0; i < length; ++i) {
            if (_l2BytecodeInfos[i].length != 0) {
                ++count;
            }
        }
        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < length; ++i) {
            if (_l2BytecodeInfos[i].length == 0) {
                continue;
            }
            deployments[cursor] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: _isZKsyncOS
                    ? IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade
                    : IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
                deployedBytecodeInfo: _l2BytecodeInfos[i],
                newAddress: L2InventoryLib.fixedAddress(L2EcosystemContract(i))
            });
            ++cursor;
        }
    }

    /// @notice The FINAL L2 deployment list: the table-derived set followed by the authored extras
    ///         (order between deployments is free; the `L2ComplexUpgrader` delegatecall runs last).
    function combineL2Deployments(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _derived,
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _extras
    ) internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory combined) {
        combined = new IComplexUpgrader.UniversalContractUpgradeInfo[](_derived.length + _extras.length);
        uint256 derivedLength = _derived.length;
        for (uint256 i = 0; i < derivedLength; ++i) {
            combined[i] = _derived[i];
        }
        uint256 extrasLength = _extras.length;
        for (uint256 i = 0; i < extrasLength; ++i) {
            combined[derivedLength + i] = _extras[i];
        }
    }

    /// @dev A release's facet rows with each facet's live self-described routing.
    function _loadRouting(ICTMRelease _release) private view returns (FacetRouting[] memory rows) {
        GenesisFacet[] memory facets = _release.genesisFacets();
        uint256 length = facets.length;
        rows = new FacetRouting[](length);
        for (uint256 i = 0; i < length; ++i) {
            rows[i] = FacetRouting({
                facet: facets[i].facet.addr,
                isFreezable: facets[i].isFreezable,
                selectors: ISelfDescribingFacet(facets[i].facet.addr).selectors()
            });
        }
    }

    /// @dev A diamond routes each selector exactly once — reject a release whose facets
    ///      collectively duplicate one. Plain pairwise scan: runs once, at transition
    ///      construction, over ~a hundred selectors.
    function _requireNoDuplicateSelectors(FacetRouting[] memory _facets) private pure {
        uint256 facetsLength = _facets.length;
        uint256 total = 0;
        for (uint256 i = 0; i < facetsLength; ++i) {
            total += _facets[i].selectors.length;
        }
        bytes4[] memory flat = new bytes4[](total);
        uint256 cursor = 0;
        for (uint256 i = 0; i < facetsLength; ++i) {
            bytes4[] memory selectors = _facets[i].selectors;
            uint256 selectorsLength = selectors.length;
            for (uint256 j = 0; j < selectorsLength; ++j) {
                for (uint256 k = 0; k < cursor; ++k) {
                    if (flat[k] == selectors[j]) {
                        revert RegistryDuplicateSelector(selectors[j]);
                    }
                }
                flat[cursor] = selectors[j];
                ++cursor;
            }
        }
    }
}
