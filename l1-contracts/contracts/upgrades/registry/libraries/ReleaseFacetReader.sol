// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {GenesisFacet} from "../RegistryTypes.sol";
import {ISelfDescribingFacet} from "../../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";

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
                facet: facets[i].facet,
                action: Diamond.Action.Add,
                isFreezable: facets[i].isFreezable,
                selectors: ISelfDescribingFacet(facets[i].facet).selectors()
            });
        }
    }
}
