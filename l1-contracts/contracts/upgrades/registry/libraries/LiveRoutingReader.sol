// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {ISelfDescribingFacet} from "../../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {LiveRoutingDiverged} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet} from "../RegistryTypes.sol";

/// @notice The live routing of the diamond the caller is delegatecalled into, read straight from
///         diamond storage: as the cuts that remove it — the remove side of a bootstrap engine's
///         full facet reinstall (see {BootstrapUpgrade}), since pre-v35 facets do not
///         self-describe — and as the check that it is still a release's.
library LiveRoutingReader {
    /// @notice One `Remove` cut per live facet, covering its complete current routing.
    /// @dev Snapshotted before anything is applied, so the mutation of the facet list during
    ///      removal cannot skew the derivation.
    function removeAllCuts() internal view returns (Diamond.FacetCut[] memory facetCuts) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        uint256 facetCount = ds.facets.length;
        facetCuts = new Diamond.FacetCut[](facetCount);
        for (uint256 i = 0; i < facetCount; ++i) {
            facetCuts[i] = Diamond.FacetCut({
                facet: address(0),
                action: Diamond.Action.Remove,
                isFreezable: false,
                selectors: ds.facetToSelectors[ds.facets[i]].selectors
            });
        }
    }

    /// @notice Reverts unless the live routing is exactly `_release`'s: the same facets, each
    ///         routing exactly the selectors it self-describes, with its row's freezability.
    /// @dev Counting is enough for equality. Every row's selectors route to its facet, so the
    ///      facet is live and routes at least those; it routes no others when the counts match,
    ///      and there is no other live facet when the facet counts match. Rows and selectors are
    ///      unique, which the release's `validate()` holds.
    function requireReleaseRouting(ICTMRelease _release) internal view {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        GenesisFacet[] memory facets = _release.genesisFacets();
        uint256 facetsLength = facets.length;
        if (ds.facets.length != facetsLength) {
            revert LiveRoutingDiverged();
        }
        for (uint256 i = 0; i < facetsLength; ++i) {
            address facet = facets[i].facet;
            bytes4[] memory selectors = ISelfDescribingFacet(facet).selectors();
            uint256 selectorsLength = selectors.length;
            if (ds.facetToSelectors[facet].selectors.length != selectorsLength) {
                revert LiveRoutingDiverged();
            }
            for (uint256 j = 0; j < selectorsLength; ++j) {
                Diamond.SelectorToFacet memory info = ds.selectorToFacet[selectors[j]];
                if (info.facetAddress != facet || info.isFreezable != facets[i].isFreezable) {
                    revert LiveRoutingDiverged();
                }
            }
        }
    }
}
