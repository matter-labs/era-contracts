// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet, ICTMRelease} from "./ICTMRelease.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";

/// @notice Turns a release's explicit facet routing into the genesis diamond cut.
/// @dev No self-description fallback: releases carry complete, reviewable selector lists
///      (enforced at release initialization), so genesis installs exactly the pinned routing.
library ReleaseFacetReader {
    function newChainInstallations(ICTMRelease _release) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        GenesisFacet[] memory facets = _release.genesisFacets();
        uint256 length = facets.length;
        facetCuts = new Diamond.FacetCut[](length);
        for (uint256 i = 0; i < length; ++i) {
            facetCuts[i] = Diamond.FacetCut({
                facet: facets[i].facet,
                action: Diamond.Action.Add,
                isFreezable: facets[i].isFreezable,
                selectors: facets[i].selectors
            });
        }
    }
}
