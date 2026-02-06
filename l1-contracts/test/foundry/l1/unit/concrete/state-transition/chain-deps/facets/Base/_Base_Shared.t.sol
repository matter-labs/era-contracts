// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsTest} from "foundry-test/l1/unit/concrete/Utils/Utils.t.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

contract TestBaseFacet is ZKChainBase {
    function functionWithOnlyAdminModifier() external onlyAdmin {}

    function functionWithOnlyValidatorModifier() external onlyValidator {}

    function functionWithOnlyChainTypeManagerModifier() external onlyChainTypeManager {}

    function functionWithOnlyBridgehubModifier() external onlyBridgehub {}

    function functionWithOnlyAdminOrChainTypeManagerModifier() external onlyAdminOrChainTypeManager {}

    function functionWithOnlyValidatorOrChainTypeManagerModifier() external onlyValidatorOrChainTypeManager {}

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

bytes constant ERROR_ONLY_ADMIN = "ZKChain: not admin";
bytes constant ERROR_ONLY_VALIDATOR = "ZKChain: not validator";
bytes constant ERROR_ONLY_STATE_TRANSITION_MANAGER = "ZKChain: not state transition manager";
bytes constant ERROR_ONLY_BRIDGEHUB = "ZKChain: not bridgehub";
bytes constant ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER = "ZKChain: Only by admin or state transition manager";
bytes constant ERROR_ONLY_VALIDATOR_OR_STATE_TRANSITION_MANAGER = "ZKChain: Only by validator or state transition manager";

contract ZKChainBaseTest is UtilsTest {
    TestBaseFacet internal testBaseFacet;
    UtilsFacet internal utilsFacet;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    DummyBridgehub internal dummyBridgehub;

    function getTestBaseFacetSelectors() public pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = TestBaseFacet.functionWithOnlyAdminModifier.selector;
        selectors[1] = TestBaseFacet.functionWithOnlyValidatorModifier.selector;
        selectors[2] = TestBaseFacet.functionWithOnlyChainTypeManagerModifier.selector;
        selectors[3] = TestBaseFacet.functionWithOnlyBridgehubModifier.selector;
        selectors[4] = TestBaseFacet.functionWithOnlyAdminOrChainTypeManagerModifier.selector;
        selectors[5] = TestBaseFacet.functionWithOnlyValidatorOrChainTypeManagerModifier.selector;
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

        dummyBridgehub = new DummyBridgehub();
        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), bytes32(0));
        mockChainTypeManagerVerifier(testnetVerifier);
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier, address(dummyBridgehub));
        testBaseFacet = TestBaseFacet(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
