// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {InvalidSelector, ValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

contract TestFacet is ZKChainBase {
    function func() public pure returns (bool) {
        return true;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract DiamondProxyTest is UtilsCallMockerTest {
    Diamond.FacetCut[] internal facetCuts;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    DummyBridgehub internal dummyBridgehub;
    InitializeData internal initializeData;

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
        dummyBridgehub = new DummyBridgehub();
        initializeData = Utils.makeInitializeData(address(dummyBridgehub));

        mockDiamondInitInteropCenterCallsWithAddress(initializeData.bridgehub, address(0), bytes32(0));
        mockChainTypeManagerVerifier(testnetVerifier);
    }

    function test_revertWhen_chainIdDiffersFromBlockChainId() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        vm.expectRevert(bytes("pr"));
        new DiamondProxy(block.chainid + 1, diamondCutData);
    }

    function test_revertWhen_calledWithEmptyMsgData() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);

        // Empty call (length 0) is allowed but fails because no facet for selector 0x00000000
        // Expected error: "F" (facet not found)
        vm.expectRevert(bytes("F"));
        address(diamondProxy).call("");
    }

    function test_revertWhen_calledWithFullSelectorInMsgData() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);

        // Call with unknown 4-byte selector fails because no facet registered
        // Expected error: "F" (facet not found)
        vm.expectRevert(bytes("F"));
        address(diamondProxy).call(bytes.concat(bytes4(0xdeadbeef)));
    }

    function test_revertWhen_calledWithPartialSelector() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);

        // Call with 1-3 bytes should trigger "Ut" error (incomplete selector)
        vm.expectRevert(bytes("Ut"));
        address(diamondProxy).call(hex"aa"); // 1 byte

        vm.expectRevert(bytes("Ut"));
        address(diamondProxy).call(hex"aabb"); // 2 bytes

        vm.expectRevert(bytes("Ut"));
        address(diamondProxy).call(hex"aabbcc"); // 3 bytes
    }

    function test_revertWhen_proxyHasNoFacetForSelector() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));

        vm.expectRevert(bytes("F"));
        testFacet.func();
    }

    function test_revertWhenFacetIsFrozen() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));
        UtilsFacet utilsFacet = UtilsFacet(address(diamondProxy));

        utilsFacet.util_setIsFrozen(true);

        vm.expectRevert(bytes("q1"));
        testFacet.func();
    }

    function test_successfulExecution() public {
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(new DiamondInit(false)),
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

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: cuts,
            initAddress: address(new DiamondInit(false)),
            initCalldata: abi.encodeWithSelector(DiamondInit.initialize.selector, initializeData)
        });

        DiamondProxy diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        TestFacet testFacet = TestFacet(address(diamondProxy));

        vm.expectRevert(bytes("F"));
        testFacet.func();
    }
}
