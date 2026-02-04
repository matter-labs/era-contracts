// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {AddressHasNoCode, DelegateCallFailed, FacetExists, NoFunctionsForDiamondCut, NonEmptyCalldata, RemoveFunctionFacetAddressNotZero, RemoveFunctionFacetAddressZero, ReplaceFunctionFacetAddressZero, SelectorsMustAllHaveSameFreezability} from "contracts/common/L1ContractErrors.sol";

/// @notice Mock facet for testing
contract MockFacet {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function multiply(uint256 a, uint256 b) external pure returns (uint256) {
        return a * b;
    }
}

/// @notice Second mock facet
contract MockFacet2 {
    function doSomething() external pure returns (string memory) {
        return "something";
    }

    function doAnother() external pure returns (string memory) {
        return "another";
    }
}

/// @notice Mock initializer that returns correct magic value
contract MockDiamondInit {
    bytes32 constant DIAMOND_INIT_SUCCESS_RETURN_VALUE =
        0x33774e659306e47509050e97cb651e731180a42d458212294d30751925c551a2;

    function init() external pure returns (bytes32) {
        return DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function initWithValue(uint256 _value) external pure returns (bytes32) {
        // Use _value to avoid warning (would normally do something with it)
        require(_value >= 0, "value check");
        return DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

/// @notice Mock initializer that returns wrong value
contract BadInitializer {
    function init() external pure returns (bytes32) {
        return bytes32(uint256(1)); // Wrong magic value
    }
}

/// @notice Mock initializer that reverts
contract RevertingInitializer {
    function init() external pure {
        revert("init failed");
    }
}

/// @notice Unit tests for Diamond library
contract DiamondTest is Test {
    MockFacet public facet1;
    MockFacet2 public facet2;
    MockDiamondInit public diamondInit;

    function setUp() public {
        facet1 = new MockFacet();
        facet2 = new MockFacet2();
        diamondInit = new MockDiamondInit();
    }

    // ============ getDiamondStorage Tests ============

    function test_getDiamondStorage_returnsStorage() public view {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        // Just check that it doesn't revert and returns a valid storage pointer
        assertFalse(ds.isFrozen);
    }

    // ============ diamondCut - Add Tests ============

    function test_diamondCut_addSingleFunction() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        Diamond.diamondCut(cutData);

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(facet1));
    }

    function test_diamondCut_addMultipleFunctions() public {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = MockFacet.setValue.selector;
        selectors[1] = MockFacet.getValue.selector;
        selectors[2] = MockFacet.multiply.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        Diamond.diamondCut(cutData);

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(facet1));
        assertEq(ds.selectorToFacet[MockFacet.getValue.selector].facetAddress, address(facet1));
        assertEq(ds.selectorToFacet[MockFacet.multiply.selector].facetAddress, address(facet1));
        assertEq(ds.facets.length, 1);
    }

    function test_diamondCut_addMultipleFacets() public {
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = MockFacet.setValue.selector;

        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = MockFacet2.doSomething.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors1
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(facet2),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors2
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        Diamond.diamondCut(cutData);

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertEq(ds.facets.length, 2);
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(facet1));
        assertEq(ds.selectorToFacet[MockFacet2.doSomething.selector].facetAddress, address(facet2));
    }

    function test_diamondCut_revertsOnEmptySelectors() public {
        bytes4[] memory selectors = new bytes4[](0);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        vm.expectRevert(NoFunctionsForDiamondCut.selector);
        Diamond.diamondCut(cutData);
    }

    function test_diamondCut_revertsOnZeroAddressFacet() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        vm.expectRevert(abi.encodeWithSelector(AddressHasNoCode.selector, address(0)));
        Diamond.diamondCut(cutData);
    }

    function test_diamondCut_revertsOnAddingExistingSelector() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        Diamond.diamondCut(cutData);

        // Try to add the same selector again
        vm.expectRevert(abi.encodeWithSelector(FacetExists.selector, MockFacet.setValue.selector, address(facet1)));
        Diamond.diamondCut(cutData);
    }

    // ============ diamondCut - Replace Tests ============

    function test_diamondCut_replaceFunction() public {
        // First add a function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory addCuts = new Diamond.FacetCut[](1);
        addCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: addCuts, initAddress: address(0), initCalldata: ""}));

        // Now replace with a new facet
        MockFacet newFacet = new MockFacet();

        Diamond.FacetCut[] memory replaceCuts = new Diamond.FacetCut[](1);
        replaceCuts[0] = Diamond.FacetCut({
            facet: address(newFacet),
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: replaceCuts, initAddress: address(0), initCalldata: ""}));

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(newFacet));
    }

    function test_diamondCut_revertsReplaceNonexistent() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        vm.expectRevert(ReplaceFunctionFacetAddressZero.selector);
        Diamond.diamondCut(cutData);
    }

    // ============ diamondCut - Remove Tests ============

    function test_diamondCut_removeFunction() public {
        // First add a function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory addCuts = new Diamond.FacetCut[](1);
        addCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: addCuts, initAddress: address(0), initCalldata: ""}));

        // Now remove the function
        Diamond.FacetCut[] memory removeCuts = new Diamond.FacetCut[](1);
        removeCuts[0] = Diamond.FacetCut({
            facet: address(0), // Must be zero for remove
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: removeCuts, initAddress: address(0), initCalldata: ""}));

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(0));
        assertEq(ds.facets.length, 0); // Facet should be removed from the list
    }

    function test_diamondCut_revertsRemoveWithNonZeroFacet() public {
        // First add a function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory addCuts = new Diamond.FacetCut[](1);
        addCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: addCuts, initAddress: address(0), initCalldata: ""}));

        // Try to remove with non-zero facet address
        Diamond.FacetCut[] memory removeCuts = new Diamond.FacetCut[](1);
        removeCuts[0] = Diamond.FacetCut({
            facet: address(facet1), // Should be zero
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: selectors
        });

        vm.expectRevert(abi.encodeWithSelector(RemoveFunctionFacetAddressNotZero.selector, address(facet1)));
        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: removeCuts, initAddress: address(0), initCalldata: ""}));
    }

    function test_diamondCut_revertsRemoveNonexistent() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory removeCuts = new Diamond.FacetCut[](1);
        removeCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: selectors
        });

        vm.expectRevert(RemoveFunctionFacetAddressZero.selector);
        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: removeCuts, initAddress: address(0), initCalldata: ""}));
    }

    // ============ diamondCut - Initialization Tests ============

    function test_diamondCut_withInitializer() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: abi.encodeWithSelector(MockDiamondInit.init.selector)
        });

        Diamond.diamondCut(cutData);

        // Verify the cut was successful
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(facet1));
    }

    function test_diamondCut_revertsOnNonEmptyCalldataWithZeroInit() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: hex"1234" // Non-empty calldata with zero address
        });

        vm.expectRevert(NonEmptyCalldata.selector);
        Diamond.diamondCut(cutData);
    }

    // ============ Freezability Tests ============

    function test_diamondCut_selectorFreezability() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: ""}));

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        assertTrue(ds.selectorToFacet[MockFacet.setValue.selector].isFreezable);
    }

    function test_diamondCut_revertsOnMixedFreezability() public {
        // First add a function with isFreezable = true
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = MockFacet.setValue.selector;

        Diamond.FacetCut[] memory addCuts = new Diamond.FacetCut[](1);
        addCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors1
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: addCuts, initAddress: address(0), initCalldata: ""}));

        // Try to add another function to the same facet with different freezability
        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = MockFacet.getValue.selector;

        Diamond.FacetCut[] memory addCuts2 = new Diamond.FacetCut[](1);
        addCuts2[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false, // Different from first selector
            selectors: selectors2
        });

        vm.expectRevert(SelectorsMustAllHaveSameFreezability.selector);
        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: addCuts2, initAddress: address(0), initCalldata: ""}));
    }

    // ============ Integration Tests ============

    function test_diamondCut_complexScenario() public {
        // Add multiple functions to facet1
        bytes4[] memory selectors1 = new bytes4[](2);
        selectors1[0] = MockFacet.setValue.selector;
        selectors1[1] = MockFacet.getValue.selector;

        // Add function to facet2
        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = MockFacet2.doSomething.selector;

        Diamond.FacetCut[] memory addCuts = new Diamond.FacetCut[](2);
        addCuts[0] = Diamond.FacetCut({
            facet: address(facet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors1
        });
        addCuts[1] = Diamond.FacetCut({
            facet: address(facet2),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors2
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: addCuts, initAddress: address(0), initCalldata: ""}));

        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        // Verify facets were added
        assertEq(ds.facets.length, 2);
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(facet1));
        assertEq(ds.selectorToFacet[MockFacet.getValue.selector].facetAddress, address(facet1));
        assertEq(ds.selectorToFacet[MockFacet2.doSomething.selector].facetAddress, address(facet2));

        // Remove one function from facet1
        bytes4[] memory removeSelectors = new bytes4[](1);
        removeSelectors[0] = MockFacet.getValue.selector;

        Diamond.FacetCut[] memory removeCuts = new Diamond.FacetCut[](1);
        removeCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: removeSelectors
        });

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: removeCuts, initAddress: address(0), initCalldata: ""}));

        // Verify function was removed but facet1 still exists
        assertEq(ds.facets.length, 2);
        assertEq(ds.selectorToFacet[MockFacet.setValue.selector].facetAddress, address(facet1));
        assertEq(ds.selectorToFacet[MockFacet.getValue.selector].facetAddress, address(0));
    }
}
