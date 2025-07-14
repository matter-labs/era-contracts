// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {ZKChainBase} from "../../state-transition/chain-deps/facets/ZKChainBase.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

/// selectors do not overlap with normal facet selectors (getName does not count)
contract DummyAdminFacetNoOverlap is ZKChainBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function getName() external pure returns (string memory) {
        return "DummyAdminFacetNoOverlap";
    }

    function executeUpgradeNoOverlap(Diamond.DiamondCutData calldata _diamondCut) external {
        Diamond.diamondCut(_diamondCut);
    }

    function receiveEther() external payable {}
}
