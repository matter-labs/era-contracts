// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {GenesisFacet} from "../RegistryTypes.sol";
import {ISelfDescribingFacet} from "../../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {IGetters} from "../../../state-transition/chain-interfaces/IGetters.sol";

/// @notice Turns a release's facet routing into the genesis diamond cut.
/// @dev Routing comes from each pinned facet's own self-description (see {GenesisFacet}), so
///      genesis installs exactly the routing the pinned code carries.
library ReleaseFacetReader {
    function newChainInstallations(ICTMRelease _release) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        GenesisFacet[] memory facets = _release.genesisFacets();
        uint256 length = facets.length;
        facetCuts = new Diamond.FacetCut[](length);
        for (uint256 i = 0; i < length; ++i) {
            facetCuts[i] = Diamond.FacetCut({
                facet: facets[i].facet.addr,
                action: Diamond.Action.Add,
                isFreezable: facets[i].isFreezable,
                selectors: ISelfDescribingFacet(facets[i].facet.addr).selectors()
            });
        }
    }

    /// @notice Whether a live chain diamond's routing is EXACTLY the release's: the same facet
    ///         addresses (no extras, no omissions) and, per facet, the same selector set as the
    ///         pinned facet's self-description. Order-insensitive on both levels.
    /// @dev Post-upgrade / monitoring read: after a chain crosses an edge its loupe output must
    ///      match the target release byte-for-byte in routing terms — the on-chain form of the
    ///      "upgrade path equals genesis path" guarantee. A view over ~a hundred selectors; the
    ///      quadratic set compare is irrelevant at that size.
    function chainMatchesRelease(ICTMRelease _release, address _chain) internal view returns (bool) {
        return chainMatchesFacetRows(_release.genesisFacets(), _chain);
    }

    /// @dev Rows-taking core of {chainMatchesRelease}, so the release object itself can serve the
    ///      check from its own decoded manifest.
    function chainMatchesFacetRows(GenesisFacet[] memory _facets, address _chain) internal view returns (bool) {
        GenesisFacet[] memory expected = _facets;
        IGetters.Facet[] memory live = IGetters(_chain).facets();

        // Facets whose self-description is empty contribute no routing (genesis installs no cut
        // for them), so only routed facets are expected in the loupe output.
        uint256 expectedRouted = 0;
        uint256 expectedLength = expected.length;
        uint256 liveLength = live.length;
        for (uint256 i = 0; i < expectedLength; ++i) {
            bytes4[] memory selectors = ISelfDescribingFacet(expected[i].facet.addr).selectors();
            if (selectors.length == 0) {
                continue;
            }
            ++expectedRouted;
            bool found = false;
            for (uint256 j = 0; j < liveLength; ++j) {
                if (live[j].addr != expected[i].facet.addr) {
                    continue;
                }
                found = _selectorSetsEqual(selectors, live[j].selectors);
                break;
            }
            if (!found) {
                return false;
            }
        }
        // No extra facets: every live facet was matched above iff the counts agree (release rows
        // are unique per address — enforced at transition derivation and by `Diamond.diamondCut`).
        return liveLength == expectedRouted;
    }

    /// @dev Order-insensitive set equality; both lists are duplicate-free (the diamond routes a
    ///      selector once, and a facet's self-description feeds `Diamond.diamondCut`, which
    ///      rejects duplicates), so equal length + one-sided containment is equality.
    function _selectorSetsEqual(bytes4[] memory _a, bytes4[] memory _b) private pure returns (bool) {
        uint256 length = _a.length;
        if (length != _b.length) {
            return false;
        }
        for (uint256 i = 0; i < length; ++i) {
            bool present = false;
            for (uint256 j = 0; j < length; ++j) {
                if (_b[j] == _a[i]) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                return false;
            }
        }
        return true;
    }
}
