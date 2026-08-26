// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet, ICTMRelease} from "../objects/ICTMRelease.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {RegistryDuplicateSelector, RegistryHashChangeToZero} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice DERIVES a transition's final diamond cuts and base-system hash changes from its
///         `(fromRelease, newRelease)` pair. The delta is a pure function of the two releases —
///         it is computed once at transition initialization and stored as ready-to-execute
///         `Diamond.FacetCut[]`, never hand-authored and never re-diffed at execution, so the
///         transition path (existing chains) cannot diverge from the release path (new chains)
///         by construction, and the chain applies the stored cuts verbatim.
///
/// @dev Scope: L1 diamond routing + the three base-system hashes. The L2 payload
///      (`L2UpgradePlan`) is reviewed-and-pinned data, not derived — L1 cannot verify L2
///      execution effects, and the guarantee is deliberately not overstated.
library TransitionDeltaLib {
    /// @dev One `selector -> (facet, freezable)` route, flattened from a release's facet rows.
    struct Route {
        bytes4 selector;
        address facet;
        bool isFreezable;
    }

    /// @notice Derives the diamond cuts whose execution transforms `_fromRelease`'s routing into
    ///         `_newRelease`'s routing exactly.
    /// @dev Emitted as one `Remove` cut per departing facet (facet address zero, per
    ///      `Diamond._removeFunctions`) followed by one `Add` cut per arriving facet — all
    ///      removals first, so selectors moving between facets are freed before being re-added.
    ///      There is no `Replace` bucket: a re-routed selector is a removal from its old facet
    ///      plus an addition to its new one. A selector survives (contributes nothing) iff the
    ///      target routes it to the SAME facet with the SAME freezability.
    function deriveFacetCuts(
        ICTMRelease _fromRelease,
        ICTMRelease _newRelease
    ) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        GenesisFacet[] memory fromFacets = _fromRelease.genesisFacets();
        GenesisFacet[] memory newFacets = _newRelease.genesisFacets();
        Route[] memory fromRouting = _expand(fromFacets);
        Route[] memory newRouting = _expand(newFacets);

        uint256 fromFacetsLength = fromFacets.length;
        uint256 newFacetsLength = newFacets.length;
        // Per from-facet: the selectors NOT carried over unchanged (removed or re-routed).
        bytes4[][] memory removedPerFacet = new bytes4[][](fromFacetsLength);
        uint256 removalCuts = 0;
        for (uint256 i = 0; i < fromFacetsLength; ++i) {
            removedPerFacet[i] = _filterRoutes(fromFacets[i], newRouting);
            if (removedPerFacet[i].length != 0) {
                ++removalCuts;
            }
        }
        // Per new-facet: the selectors NOT already routed identically in `fromRelease`.
        bytes4[][] memory addedPerFacet = new bytes4[][](newFacetsLength);
        uint256 additionCuts = 0;
        for (uint256 i = 0; i < newFacetsLength; ++i) {
            addedPerFacet[i] = _filterRoutes(newFacets[i], fromRouting);
            if (addedPerFacet[i].length != 0) {
                ++additionCuts;
            }
        }

        facetCuts = new Diamond.FacetCut[](removalCuts + additionCuts);
        uint256 cursor = 0;
        for (uint256 i = 0; i < fromFacetsLength; ++i) {
            if (removedPerFacet[i].length != 0) {
                facetCuts[cursor] = Diamond.FacetCut({
                    facet: address(0),
                    action: Diamond.Action.Remove,
                    isFreezable: false,
                    selectors: removedPerFacet[i]
                });
                ++cursor;
            }
        }
        for (uint256 i = 0; i < newFacetsLength; ++i) {
            if (addedPerFacet[i].length != 0) {
                facetCuts[cursor] = Diamond.FacetCut({
                    facet: newFacets[i].facet,
                    action: Diamond.Action.Add,
                    isFreezable: newFacets[i].isFreezable,
                    selectors: addedPerFacet[i]
                });
                ++cursor;
            }
        }
    }

    /// @notice Derives the base-system hash CHANGES: the target value where the releases differ,
    ///         zero (= leave unchanged, the `BaseZkSyncUpgrade` convention) where they agree.
    function deriveHashChanges(
        ICTMRelease _fromRelease,
        ICTMRelease _newRelease
    ) internal view returns (bytes32 bootloaderChange, bytes32 defaultAccountChange, bytes32 evmEmulatorChange) {
        (bytes32 fromBootloader, bytes32 fromDefaultAccount, bytes32 fromEvmEmulator) = _fromRelease
            .baseSystemContractHashes();
        (bytes32 newBootloader, bytes32 newDefaultAccount, bytes32 newEvmEmulator) = _newRelease
            .baseSystemContractHashes();
        bootloaderChange = _deriveHashChange(fromBootloader, newBootloader);
        defaultAccountChange = _deriveHashChange(fromDefaultAccount, newDefaultAccount);
        evmEmulatorChange = _deriveHashChange(fromEvmEmulator, newEvmEmulator);
    }

    /// @dev The stored change for one base-system hash: zero when the releases agree.
    ///      A nonzero -> zero change is NOT representable, because `BaseZkSyncUpgrade` reads zero
    ///      as "leave unchanged": existing chains would keep the old hash while new chains take the
    ///      target release's zero, so the two paths would diverge. Reject it at derivation rather
    ///      than store a silent no-op.
    function _deriveHashChange(bytes32 _fromHash, bytes32 _newHash) private pure returns (bytes32) {
        if (_fromHash == _newHash) {
            return bytes32(0);
        }
        if (_newHash == bytes32(0)) {
            revert RegistryHashChangeToZero();
        }
        return _newHash;
    }

    /// @dev The selectors of `_facet` that do NOT appear in `_otherRouting` with the same facet
    ///      address and freezability — i.e. the ones this side of the delta must act on.
    function _filterRoutes(
        GenesisFacet memory _facet,
        Route[] memory _otherRouting
    ) private pure returns (bytes4[] memory result) {
        bytes4[] memory selectors = _facet.selectors;
        uint256 selectorsLength = selectors.length;
        uint256 count = 0;
        bool[] memory acts = new bool[](selectorsLength);
        for (uint256 i = 0; i < selectorsLength; ++i) {
            if (!_routedIdentically(_otherRouting, selectors[i], _facet.facet, _facet.isFreezable)) {
                acts[i] = true;
                ++count;
            }
        }
        result = new bytes4[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < selectorsLength; ++i) {
            if (acts[i]) {
                result[cursor] = selectors[i];
                ++cursor;
            }
        }
    }

    function _routedIdentically(
        Route[] memory _routing,
        bytes4 _selector,
        address _facet,
        bool _isFreezable
    ) private pure returns (bool) {
        uint256 routingLength = _routing.length;
        for (uint256 i = 0; i < routingLength; ++i) {
            if (_routing[i].selector == _selector) {
                return _routing[i].facet == _facet && _routing[i].isFreezable == _isFreezable;
            }
        }
        return false;
    }

    /// @dev Flattens facet rows into one route per selector, rejecting duplicate selectors —
    ///      a diamond routes each selector exactly once, so a duplicated selector in a release's
    ///      routing is a malformed manifest.
    function _expand(GenesisFacet[] memory _facets) private pure returns (Route[] memory routes) {
        uint256 facetsLength = _facets.length;
        uint256 total = 0;
        for (uint256 i = 0; i < facetsLength; ++i) {
            total += _facets[i].selectors.length;
        }
        routes = new Route[](total);
        uint256 cursor = 0;
        for (uint256 i = 0; i < facetsLength; ++i) {
            bytes4[] memory selectors = _facets[i].selectors;
            uint256 selectorsLength = selectors.length;
            for (uint256 j = 0; j < selectorsLength; ++j) {
                for (uint256 k = 0; k < cursor; ++k) {
                    if (routes[k].selector == selectors[j]) {
                        revert RegistryDuplicateSelector(selectors[j]);
                    }
                }
                routes[cursor] = Route({
                    selector: selectors[j],
                    facet: _facets[i].facet,
                    isFreezable: _facets[i].isFreezable
                });
                ++cursor;
            }
        }
    }
}
