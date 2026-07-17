// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet, ICTMRelease} from "./ICTMRelease.sol";
import {UpgradeFacetSwap} from "../../state-transition/libraries/ProposedUpgradeLib.sol";
import {ISelfDescribingFacet} from "../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {
    TransitionAddsPresentSelector,
    TransitionBaseSystemHashMismatch,
    TransitionFacetCountMismatch,
    TransitionFacetFreezableMismatch,
    TransitionFacetRoutingMismatch,
    TransitionRemovesAbsentSelector
} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Proves on-chain that a {CTMTransition} actually *produces* its target {CTMRelease}.
///
/// A new chain installs its facets and base-system hashes straight from the release
/// ({ReleaseFacetReader.newChainInstallations} / `release.baseSystemContractHashes`). An existing
/// chain instead applies the transition's own `facetTransitions` / `baseSystemContractHashChanges`.
/// Nothing else forces those two representations to agree, so without this check a transition could
/// install a facet — or base-system hash — that no fresh chain at `newRelease` ever runs, and that
/// the release never pinned. This library closes that gap: it replays the transition's facet swaps
/// against `fromRelease`'s routing and asserts the result is byte-for-byte `newRelease`'s routing,
/// and reconciles the applied base-system hash changes against `newRelease`'s pinned hashes. Once
/// this holds, the release's own codehash pins transitively cover the transition's facets.
///
/// @dev The pre-registry migration hop (`fromRelease == address(0)`, e.g. v31 -> v32) is skipped:
///      the chain's prior on-chain facet set is not captured by any release object, so convergence
///      cannot be reconstructed here. That one-time hop is covered by manual migration audit.
library TransitionConvergenceLib {
    /// @dev A single `selector -> facet` route in a diamond, plus whether the route is still live
    ///      after removals. Working set for replaying `facetTransitions`.
    struct Route {
        bytes4 selector;
        address facet;
        bool isFreezable;
        bool live;
    }

    /// @notice Reverts unless applying `_swaps` and the base-system hash changes to `_fromRelease`
    ///         reproduces `_newRelease` exactly.
    /// @param _fromRelease The release the CTM is at before the hop (`address(0)` for the
    ///        pre-registry migration hop, which is skipped).
    /// @param _swaps The transition's facet swaps (`facetTransitions`).
    /// @param _newRelease The release the transition targets.
    /// @param _bootloaderChange Applied bootloader hash change (zero = leave unchanged).
    /// @param _defaultAccountChange Applied default-account hash change (zero = leave unchanged).
    /// @param _evmEmulatorChange Applied EVM-emulator hash change (zero = leave unchanged).
    function requireTransitionProducesRelease(
        address _fromRelease,
        UpgradeFacetSwap[] memory _swaps,
        address _newRelease,
        bytes32 _bootloaderChange,
        bytes32 _defaultAccountChange,
        bytes32 _evmEmulatorChange
    ) internal view {
        if (_fromRelease == address(0)) {
            return;
        }

        _requireBaseSystemHashesConverge(
            _fromRelease,
            _newRelease,
            _bootloaderChange,
            _defaultAccountChange,
            _evmEmulatorChange
        );
        _requireFacetsConverge(_fromRelease, _swaps, _newRelease);
    }

    /// @dev For each base-system hash, the effective post-transition value — the change when set,
    ///      otherwise the value carried from `fromRelease` — must equal `newRelease`'s pinned value.
    function _requireBaseSystemHashesConverge(
        address _fromRelease,
        address _newRelease,
        bytes32 _bootloaderChange,
        bytes32 _defaultAccountChange,
        bytes32 _evmEmulatorChange
    ) private view {
        (bytes32 fromBootloader, bytes32 fromDefaultAccount, bytes32 fromEvmEmulator) = ICTMRelease(_fromRelease)
            .baseSystemContractHashes();
        (bytes32 newBootloader, bytes32 newDefaultAccount, bytes32 newEvmEmulator) = ICTMRelease(_newRelease)
            .baseSystemContractHashes();

        _requireEffective(fromBootloader, _bootloaderChange, newBootloader);
        _requireEffective(fromDefaultAccount, _defaultAccountChange, newDefaultAccount);
        _requireEffective(fromEvmEmulator, _evmEmulatorChange, newEvmEmulator);
    }

    function _requireEffective(bytes32 _from, bytes32 _change, bytes32 _target) private pure {
        bytes32 effective = _change != bytes32(0) ? _change : _from;
        if (effective != _target) {
            revert TransitionBaseSystemHashMismatch(_target, effective);
        }
    }

    /// @dev Replays the swaps over `fromRelease`'s routing (all removals first, then all additions —
    ///      mirroring how the diamond cut groups Remove before Add) and asserts the live result
    ///      matches `newRelease`'s routing selector-for-selector, facet-for-facet, freezable-for-freezable.
    function _requireFacetsConverge(
        address _fromRelease,
        UpgradeFacetSwap[] memory _swaps,
        address _newRelease
    ) private view {
        Route[] memory target = _expand(ICTMRelease(_newRelease).genesisFacets());

        Route[] memory fromRouting = _expand(ICTMRelease(_fromRelease).genesisFacets());
        uint256 fromLen = fromRouting.length;

        // Upper bound on live routes: the carried-over routes plus every added selector.
        uint256 addedUpperBound = 0;
        uint256 swapsLen = _swaps.length;
        for (uint256 i = 0; i < swapsLen; ++i) {
            addedUpperBound += _resolveSelectors(_swaps[i].newFacet, _swaps[i].newSelectors).length;
        }
        Route[] memory working = new Route[](fromLen + addedUpperBound);
        for (uint256 i = 0; i < fromLen; ++i) {
            working[i] = fromRouting[i];
        }
        uint256 workingLen = fromLen;

        // Pass 1: removals. Every old selector must currently be live and routed to `oldFacet`.
        for (uint256 i = 0; i < swapsLen; ++i) {
            address oldFacet = _swaps[i].oldFacet;
            bytes4[] memory oldSelectors = _resolveSelectors(oldFacet, _swaps[i].oldSelectors);
            uint256 oldSelectorsLen = oldSelectors.length;
            for (uint256 j = 0; j < oldSelectorsLen; ++j) {
                bytes4 selector = oldSelectors[j];
                uint256 idx = _findLive(working, workingLen, selector);
                if (idx == type(uint256).max || working[idx].facet != oldFacet) {
                    revert TransitionRemovesAbsentSelector(selector, oldFacet);
                }
                working[idx].live = false;
            }
        }

        // Pass 2: additions. Every new selector must be absent (post-removal) and is routed to `newFacet`.
        for (uint256 i = 0; i < swapsLen; ++i) {
            address newFacet = _swaps[i].newFacet;
            bool isFreezable = _swaps[i].isFreezable;
            bytes4[] memory newSelectors = _resolveSelectors(newFacet, _swaps[i].newSelectors);
            uint256 newSelectorsLen = newSelectors.length;
            for (uint256 j = 0; j < newSelectorsLen; ++j) {
                bytes4 selector = newSelectors[j];
                if (_findLive(working, workingLen, selector) != type(uint256).max) {
                    revert TransitionAddsPresentSelector(selector);
                }
                working[workingLen] = Route({
                    selector: selector,
                    facet: newFacet,
                    isFreezable: isFreezable,
                    live: true
                });
                ++workingLen;
            }
        }

        _requireSameRouting(working, workingLen, target);
    }

    /// @dev Asserts the live routes in `_working[0.._workingLen)` are exactly `_target`: same count,
    ///      and every target selector routes to the same facet with the same freezable flag.
    function _requireSameRouting(Route[] memory _working, uint256 _workingLen, Route[] memory _target) private pure {
        uint256 liveCount = 0;
        for (uint256 i = 0; i < _workingLen; ++i) {
            if (_working[i].live) {
                ++liveCount;
            }
        }
        if (liveCount != _target.length) {
            revert TransitionFacetCountMismatch(_target.length, liveCount);
        }

        // Equal live-count + unique selectors on both sides means matching every target entry to a
        // live route is a bijection; a duplicate or missing selector cannot slip through.
        uint256 targetLen = _target.length;
        for (uint256 i = 0; i < targetLen; ++i) {
            bytes4 selector = _target[i].selector;
            uint256 idx = _findLive(_working, _workingLen, selector);
            if (idx == type(uint256).max) {
                revert TransitionFacetRoutingMismatch(selector, _target[i].facet, address(0));
            }
            if (_working[idx].facet != _target[i].facet) {
                revert TransitionFacetRoutingMismatch(selector, _target[i].facet, _working[idx].facet);
            }
            if (_working[idx].isFreezable != _target[i].isFreezable) {
                revert TransitionFacetFreezableMismatch(selector);
            }
        }
    }

    /// @dev Flattens genesis facets into one route per selector, resolving each facet's selector
    ///      list exactly as {ReleaseFacetReader.newChainInstallations} does (self-describing facet
    ///      unless a list is explicitly pinned).
    function _expand(GenesisFacet[] memory _facets) private view returns (Route[] memory routes) {
        uint256 facetsLen = _facets.length;
        uint256 total = 0;
        bytes4[][] memory perFacet = new bytes4[][](facetsLen);
        for (uint256 i = 0; i < facetsLen; ++i) {
            perFacet[i] = _facets[i].selectors.length == 0
                ? ISelfDescribingFacet(_facets[i].facet).selectors()
                : _facets[i].selectors;
            total += perFacet[i].length;
        }

        routes = new Route[](total);
        uint256 cursor = 0;
        for (uint256 i = 0; i < facetsLen; ++i) {
            uint256 selectorsLen = perFacet[i].length;
            for (uint256 j = 0; j < selectorsLen; ++j) {
                routes[cursor] = Route({
                    selector: perFacet[i][j],
                    facet: _facets[i].facet,
                    isFreezable: _facets[i].isFreezable,
                    live: true
                });
                ++cursor;
            }
        }
    }

    /// @dev Resolves a swap side's selector list the same way `BaseZkSyncUpgrade._resolveFacetSelectors`
    ///      does: a zero facet (pure add/remove counterpart) or a pinned list is returned verbatim,
    ///      otherwise the facet self-describes.
    function _resolveSelectors(address _facet, bytes4[] memory _pinned) private view returns (bytes4[] memory) {
        if (_facet == address(0) || _pinned.length != 0) {
            return _pinned;
        }
        return ISelfDescribingFacet(_facet).selectors();
    }

    /// @dev Index of the live route serving `_selector`, or `type(uint256).max` if none. Selectors
    ///      are unique among live routes (a diamond routes each selector once), so the first hit is
    ///      the only hit.
    function _findLive(Route[] memory _routes, uint256 _len, bytes4 _selector) private pure returns (uint256) {
        for (uint256 i = 0; i < _len; ++i) {
            if (_routes[i].live && _routes[i].selector == _selector) {
                return i;
            }
        }
        return type(uint256).max;
    }
}
