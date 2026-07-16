// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet, ICTMRelease} from "./ICTMRelease.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {ISelfDescribingFacet} from "../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";

library ReleaseFacetReader {
    function newChainInstallations(ICTMRelease _release) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        GenesisFacet[] memory facets = _release.genesisFacets();
        uint256 length = facets.length;
        facetCuts = new Diamond.FacetCut[](length);
        for (uint256 i = 0; i < length; ++i) {
            bytes4[] memory selectors = facets[i].selectors;
            facetCuts[i] = Diamond.FacetCut({
                facet: facets[i].facet,
                action: Diamond.Action.Add,
                isFreezable: facets[i].isFreezable,
                selectors: selectors.length == 0 ? ISelfDescribingFacet(facets[i].facet).selectors() : selectors
            });
        }
    }
}
