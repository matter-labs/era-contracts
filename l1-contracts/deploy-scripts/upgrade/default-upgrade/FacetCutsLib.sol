// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

library FacetCutsLib {
    error NotLatestProtocolVersion();

    function merge(
        Diamond.FacetCut[] memory _a,
        Diamond.FacetCut[] memory _b
    ) internal pure returns (Diamond.FacetCut[] memory result) {
        result = new Diamond.FacetCut[](_a.length + _b.length);
        for (uint256 i = 0; i < _a.length; i++) {
            result[i] = _a[i];
        }
        for (uint256 i = 0; i < _b.length; i++) {
            result[_a.length + i] = _b[i];
        }
    }

    function getDeletionCuts(address _diamond) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        IZKChain.Facet[] memory facets = IZKChain(_diamond).facets();

        require(
            IZKChain(_diamond).getProtocolVersion() ==
                IChainTypeManager(IZKChain(_diamond).getChainTypeManager()).protocolVersion(),
            NotLatestProtocolVersion()
        );

        facetCuts = new Diamond.FacetCut[](facets.length);
        for (uint256 i = 0; i < facets.length; i++) {
            facetCuts[i] = Diamond.FacetCut({
                facet: address(0),
                action: Diamond.Action.Remove,
                isFreezable: false,
                selectors: facets[i].selectors
            });
        }
    }
}
