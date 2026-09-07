// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "../../../state-transition/libraries/Diamond.sol";

/// @notice The departing routing of the diamond the caller is delegatecalled into, as the cuts
///         that remove it — the remove side of a bootstrap engine's full facet reinstall (see
///         {BootstrapUpgradeZKsyncOS}). Pre-v34 facets do not self-describe, so the routing is read
///         straight from diamond storage.
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
}
