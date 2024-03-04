// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {InitializeData} from "solpp/state-transition/chain-interfaces/IDiamondInit.sol";
import {DiamondInit} from "solpp/state-transition/chain-deps/DiamondInit.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {GettersFacet} from "solpp/state-transition/chain-deps/facets/Getters.sol";
import {IVerifier, VerifierParams} from "solpp/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode, ZkSyncStateTransitionStorage} from "solpp/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {DiamondProxy} from "solpp/state-transition/chain-deps/DiamondProxy.sol";
import {MAX_GAS_PER_TRANSACTION} from "solpp/common/Config.sol";
import {ZkSyncStateTransitionBase} from "solpp/state-transition/chain-deps/facets/ZkSyncStateTransitionBase.sol";

contract TestFacet is ZkSyncStateTransitionBase {
    function func() public pure returns (bool) {
        return true;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract DiamondInitTest is Test {
    Diamond.FacetCut[] internal facetCuts;

    function getTestFacetSelectors() public pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = TestFacet.func.selector;
    }

    function setUp() public virtual {
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new TestFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: getTestFacetSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
    }

    function test_revertWhen_chainIdDiffersFromBlockChainId() public {
        InitializeData memory initializeData = Utils.makeInitializeData();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(abi.encodePacked("pr"));
        new DiamondProxy(block.chainid + 1, diamondCutData);
    }

    function test_revertWhen_calledWithEmptyMsgData() public {
        InitializeData memory initializeData = Utils.makeInitializeData();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);

        vm.expectRevert(abi.encodePacked("Ut"));
        (bool success, ) = address(diamondProxy).call("");
        assertEq(success, false);
    }

    function test_revertWhen_calledWithFullSelectorInMsgData() public {
        InitializeData memory initializeData = Utils.makeInitializeData();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);

        vm.expectRevert(abi.encodePacked("Ut"));
        (bool success, ) = address(diamondProxy).call(bytes.concat(bytes4(0xdeadbeef)));
        assertEq(success, false);
    }

    function test_revertWhen_proxyHasNoFacetForSelector() public {
        InitializeData memory initializeData = Utils.makeInitializeData();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));

        vm.expectRevert(abi.encodePacked("F"));
        testFacet.func();
    }

    function test_revertWhenFacetIsFrozen() public {
        InitializeData memory initializeData = Utils.makeInitializeData();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));
        UtilsFacet utilsFacet = UtilsFacet(address(diamondProxy));

        utilsFacet.util_setIsFrozen(true);

        vm.expectRevert(abi.encodePacked("q1"));
        testFacet.func();
    }

    function test_successfulExecution() public {
        InitializeData memory initializeData = Utils.makeInitializeData();

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));

        assertEq(testFacet.func(), true);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
