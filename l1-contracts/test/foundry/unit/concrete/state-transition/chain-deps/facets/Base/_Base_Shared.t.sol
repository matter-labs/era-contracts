// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {ZkSyncStateTransitionBase} from "solpp/state-transition/chain-deps/facets/Admin.sol";

contract TestBaseFacet is ZkSyncStateTransitionBase {
    function functionWithOnlyAdminModifier() external onlyAdmin {}

    function functionWithOnlyValidatorModifier() external onlyValidator {}

    function functionWithOnlyStateTransitionManagerModifier() external onlyStateTransitionManager {}

    function functionWithOnlyBridgehubModifier() external onlyBridgehub {}

    function functionWithOnlyAdminOrStateTransitionManagerModifier() external onlyAdminOrStateTransitionManager {}

    function functionWithonlyValidatorOrStateTransitionManagerModifier()
        external
        onlyValidatorOrStateTransitionManager
    {}

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

bytes constant ERROR_ONLY_ADMIN = "StateTransition Chain: not admin";
bytes constant ERROR_ONLY_VALIDATOR = "StateTransition Chain: not validator";
bytes constant ERROR_ONLY_STATE_TRANSITION_MANAGER = "StateTransition Chain: not state transition manager";
bytes constant ERROR_ONLY_BRIDGEHUB = "StateTransition Chain: not bridgehub";
bytes constant ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER = "StateTransition Chain: Only by admin or state transition manager";
bytes constant ERROR_ONLY_VALIDATOR_OR_STATE_TRANSITION_MANAGER = "StateTransition Chain: Only by validator or state transition manager";

contract ZkSyncStateTransitionBaseTest is Test {
    TestBaseFacet internal testBaseFacet;
    UtilsFacet internal utilsFacet;

    function getTestBaseFacetSelectors() public pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = TestBaseFacet.functionWithOnlyAdminModifier.selector;
        selectors[1] = TestBaseFacet.functionWithOnlyValidatorModifier.selector;
        selectors[2] = TestBaseFacet.functionWithOnlyStateTransitionManagerModifier.selector;
        selectors[3] = TestBaseFacet.functionWithOnlyBridgehubModifier.selector;
        selectors[4] = TestBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier.selector;
        selectors[5] = TestBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier.selector;
    }

    function setUp() public virtual {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new TestBaseFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getTestBaseFacetSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        address diamondProxy = Utils.makeDiamondProxy(facetCuts);
        testBaseFacet = TestBaseFacet(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
