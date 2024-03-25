// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";

contract DiamondInitTest is Test {
    Diamond.FacetCut[] internal facetCuts;
    address internal testnetVerifier = address(new TestnetVerifier());

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
