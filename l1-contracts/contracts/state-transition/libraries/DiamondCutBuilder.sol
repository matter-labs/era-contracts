// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Diamond} from "./Diamond.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Computes `Diamond.FacetCut[]` diffs from facet swaps, so that diamond upgrades can be
///         composed on-chain from selector lists instead of hand-authored cut calldata.
/// @dev A swap replaces `oldFacet` (with the selectors it currently serves) by `newFacet` (with
///      the selectors it declares). Selectors present in both sides become `Replace`, old-only
///      selectors become `Remove`, new-only selectors become `Add`. A zero `oldFacet` expresses a
///      pure addition (e.g. the initial cut of a newly created chain); a zero `newFacet` expresses
///      a pure removal.
library DiamondCutBuilder {
    /// @dev A single facet replacement.
    /// @param oldFacet The facet currently serving selectors, or zero for a pure addition.
    /// @param newFacet The facet to serve selectors after the cut, or zero for a pure removal.
    /// @param isFreezable Whether the new facet's selectors can be frozen (see `Diamond.FacetCut`).
    // solhint-disable-next-line gas-struct-packing
    struct FacetSwap {
        address oldFacet;
        address newFacet;
        bool isFreezable;
    }

    /// @notice Builds the facet cuts realizing the given swaps.
    /// @dev Cuts are emitted grouped by action — all `Remove` cuts first, then `Replace`, then
    ///      `Add` — so that a selector moving between two facets of different swaps is removed
    ///      before it is re-added, regardless of swap order.
    /// @param _swaps The facet swaps to realize.
    /// @param _oldSelectors Per swap, the selectors `oldFacet` currently serves (empty iff
    ///        `oldFacet` is zero). Read from diamond storage or from the previous version's
    ///        registry, depending on the caller.
    /// @param _newSelectors Per swap, the selectors `newFacet` declares (empty iff `newFacet` is
    ///        zero). Read from the facet itself (`ISelfDescribingFacet.selectors()`) or from the
    ///        new version's registry.
    /// @return facetCuts The cuts to feed into `Diamond.diamondCut`; only non-empty cuts are
    ///         emitted, so swaps whose diff is empty contribute nothing.
    function buildCuts(
        FacetSwap[] memory _swaps,
        bytes4[][] memory _oldSelectors,
        bytes4[][] memory _newSelectors
    ) internal pure returns (Diamond.FacetCut[] memory facetCuts) {
        uint256 swapsLength = _swaps.length;

        bytes4[][] memory removed = new bytes4[][](swapsLength);
        bytes4[][] memory replaced = new bytes4[][](swapsLength);
        bytes4[][] memory added = new bytes4[][](swapsLength);

        uint256 cutsCount = 0;
        for (uint256 i = 0; i < swapsLength; ++i) {
            (removed[i], replaced[i], added[i]) = splitSelectors(_oldSelectors[i], _newSelectors[i]);
            if (removed[i].length != 0) {
                ++cutsCount;
            }
            if (replaced[i].length != 0) {
                ++cutsCount;
            }
            if (added[i].length != 0) {
                ++cutsCount;
            }
        }

        facetCuts = new Diamond.FacetCut[](cutsCount);
        uint256 cutIndex = 0;
        // All removals go first so that selectors moving across swaps are freed before re-adding.
        for (uint256 i = 0; i < swapsLength; ++i) {
            if (removed[i].length != 0) {
                facetCuts[cutIndex] = Diamond.FacetCut({
                    facet: address(0),
                    action: Diamond.Action.Remove,
                    isFreezable: false,
                    selectors: removed[i]
                });
                ++cutIndex;
            }
        }
        for (uint256 i = 0; i < swapsLength; ++i) {
            if (replaced[i].length != 0) {
                facetCuts[cutIndex] = Diamond.FacetCut({
                    facet: _swaps[i].newFacet,
                    action: Diamond.Action.Replace,
                    isFreezable: _swaps[i].isFreezable,
                    selectors: replaced[i]
                });
                ++cutIndex;
            }
        }
        for (uint256 i = 0; i < swapsLength; ++i) {
            if (added[i].length != 0) {
                facetCuts[cutIndex] = Diamond.FacetCut({
                    facet: _swaps[i].newFacet,
                    action: Diamond.Action.Add,
                    isFreezable: _swaps[i].isFreezable,
                    selectors: added[i]
                });
                ++cutIndex;
            }
        }
    }

    /// @notice Splits an (old, new) selector pair into the three diff buckets.
    /// @dev Selector lists are expected to be duplicate-free; old lists read from diamond storage
    ///      are duplicate-free by construction, and a duplicate in a new list produces a duplicate
    ///      `Add` that `Diamond.diamondCut` rejects.
    /// @return removed Selectors only in `_old` (to be removed from the diamond).
    /// @return replaced Selectors in both (to be re-pointed to the new facet).
    /// @return added Selectors only in `_new` (to be added to the diamond).
    function splitSelectors(
        bytes4[] memory _old,
        bytes4[] memory _new
    ) internal pure returns (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) {
        uint256 oldLength = _old.length;
        uint256 newLength = _new.length;

        uint256 replacedCount = 0;
        for (uint256 i = 0; i < oldLength; ++i) {
            if (_contains(_new, _old[i])) {
                ++replacedCount;
            }
        }
        uint256 addedCount = 0;
        for (uint256 i = 0; i < newLength; ++i) {
            if (!_contains(_old, _new[i])) {
                ++addedCount;
            }
        }

        removed = new bytes4[](oldLength - replacedCount);
        replaced = new bytes4[](replacedCount);
        added = new bytes4[](addedCount);

        uint256 removedIndex = 0;
        uint256 replacedIndex = 0;
        for (uint256 i = 0; i < oldLength; ++i) {
            if (_contains(_new, _old[i])) {
                replaced[replacedIndex] = _old[i];
                ++replacedIndex;
            } else {
                removed[removedIndex] = _old[i];
                ++removedIndex;
            }
        }
        uint256 addedIndex = 0;
        for (uint256 i = 0; i < newLength; ++i) {
            if (!_contains(_old, _new[i])) {
                added[addedIndex] = _new[i];
                ++addedIndex;
            }
        }
    }

    /// @dev Linear membership test; selector lists are small (tens of entries).
    function _contains(bytes4[] memory _selectors, bytes4 _selector) private pure returns (bool) {
        uint256 selectorsLength = _selectors.length;
        for (uint256 i = 0; i < selectorsLength; ++i) {
            if (_selectors[i] == _selector) {
                return true;
            }
        }
        return false;
    }
}
