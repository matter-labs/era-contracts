// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {ZkSyncHyperchainBase} from "contracts/state-transition/chain-deps/facets/ZkSyncHyperchainBase.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";

contract TestFacet is ZkSyncHyperchainBase {
    function func() public pure returns (bool) {
        return true;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract DiamondProxyTest is Test {
    Diamond.FacetCut[] internal facetCuts;
    address internal testnetVerifier = address(new TestnetVerifier());

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
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(abi.encodePacked("pr"));
        new DiamondProxy(block.chainid + 1, diamondCutData);
    }

    function test_revertWhen_calledWithEmptyMsgData() public {
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

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
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

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
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

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
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

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
        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));

        assertEq(testFacet.func(), true);
    }

    function test_revertWhen_removeFunctions() public {
        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](3);
        cuts[0] = facetCuts[0];
        cuts[1] = facetCuts[1];
        cuts[2] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: true,
            selectors: getTestFacetSelectors()
        });

        InitializeData memory initializeData = Utils.makeInitializeData(testnetVerifier);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: cuts,
            initAddress: address(new DiamondInit()),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));

        vm.expectRevert(bytes("F"));
        testFacet.func();
    }
}
