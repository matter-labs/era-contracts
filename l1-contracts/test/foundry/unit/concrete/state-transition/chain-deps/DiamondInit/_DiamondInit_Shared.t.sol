// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";

contract DiamondInitTest is Test {
    Diamond.FacetCut[] internal facetCuts;

    function setUp() public virtual {
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
