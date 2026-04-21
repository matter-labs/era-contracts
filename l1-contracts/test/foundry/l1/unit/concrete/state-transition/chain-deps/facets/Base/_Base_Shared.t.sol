// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {Utils as UnitUtils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
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

contract ZKChainBaseTest is MigrationTestBase {
    TestBaseFacet internal testBaseFacet;
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

    function setUp() public virtual override {
        _deployIntegrationBase();
        dummyBridgehub = new DummyBridgehub();

        // Add TestBaseFacet to the deployed chain for testing modifiers
        TestBaseFacet facetImpl = new TestBaseFacet();
        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](1);
        cuts[0] = Diamond.FacetCut({
            facet: address(facetImpl),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getTestBaseFacetSelectors()
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: cuts,
            initAddress: address(0),
            initCalldata: ""
        });

        address ctm = IZKChain(chainAddress).getChainTypeManager();
        vm.prank(ctm);
        IAdmin(chainAddress).executeUpgrade(cutData);

        testBaseFacet = TestBaseFacet(chainAddress);
    }

    // add this to be excluded from coverage report
    function testBaseShared() internal virtual {}
}
