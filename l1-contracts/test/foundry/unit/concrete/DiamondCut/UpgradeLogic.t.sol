// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// solhint-disable max-line-length

import {DiamondCutTest} from "./_DiamondCut_Shared.t.sol";
import {DiamondCutTestContract} from "../../../../../cache/solpp-generated-contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {DiamondInit} from "../../../../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import {DiamondProxy} from "../../../../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";
import {VerifierParams} from "../../../../../cache/solpp-generated-contracts/zksync/Storage.sol";
import {AdminFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Admin.sol";
import {GettersFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import {Diamond} from "../../../../../cache/solpp-generated-contracts/zksync/libraries/Diamond.sol";
import {Utils} from "../Utils/Utils.sol";

// solhint-enable max-line-length

contract UpgradeLogicTest is DiamondCutTest {
    DiamondProxy private diamondProxy;
    DiamondInit private diamondInit;
    AdminFacet private adminFacet;
    AdminFacet private proxyAsAdmin;
    GettersFacet private proxyAsGetters;
    address private governor;
    address private randomSigner;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory dcSelectors = new bytes4[](10);
        dcSelectors[0] = adminFacet.setPendingGovernor.selector;
        dcSelectors[1] = adminFacet.acceptGovernor.selector;
        dcSelectors[2] = adminFacet.setPendingAdmin.selector;
        dcSelectors[3] = adminFacet.acceptAdmin.selector;
        dcSelectors[4] = adminFacet.setValidator.selector;
        dcSelectors[5] = adminFacet.setPorterAvailability.selector;
        dcSelectors[6] = adminFacet.setPriorityTxMaxGasLimit.selector;
        dcSelectors[7] = adminFacet.executeUpgrade.selector;
        dcSelectors[8] = adminFacet.freezeDiamond.selector;
        dcSelectors[9] = adminFacet.unfreezeDiamond.selector;
        return dcSelectors;
    }

    function setUp() public {
        governor = makeAddr("governor");
        randomSigner = makeAddr("randomSigner");

        diamondCutTestContract = new DiamondCutTestContract();
        diamondInit = new DiamondInit();
        adminFacet = new AdminFacet();
        gettersFacet = new GettersFacet();

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(adminFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getGettersSelectors()
        });

        VerifierParams memory dummyVerifierParams = VerifierParams({
            recursionNodeLevelVkHash: 0,
            recursionLeafLevelVkHash: 0,
            recursionCircuitsSetVksHash: 0
        });

        bytes memory diamondInitCalldata = abi.encodeWithSelector(
            diamondInit.initialize.selector,
            0x03752D8252d67f99888E741E3fB642803B29B155,
            governor,
            governor,
            0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21,
            0,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            dummyVerifierParams,
            false,
            0x0100000000000000000000000000000000000000000000000000000000000000,
            0x0100000000000000000000000000000000000000000000000000000000000000,
            500000, // priority tx max L2 gas limit
            0
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitCalldata
        });

        diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        proxyAsAdmin = AdminFacet(address(diamondProxy));
        proxyAsGetters = GettersFacet(address(diamondProxy));
    }

    function test_RevertWhen_EmergencyFreezeWhenUnauthurizedGovernor() public {
        vm.startPrank(randomSigner);

        vm.expectRevert(abi.encodePacked("1g"));
        proxyAsAdmin.freezeDiamond();
    }

    function test_RevertWhen_DoubleFreezingByGovernor() public {
        vm.startPrank(governor);

        proxyAsAdmin.freezeDiamond();

        vm.expectRevert(abi.encodePacked("a9"));
        proxyAsAdmin.freezeDiamond();
    }

    function test_RevertWhen_UnfreezingWhenNotFrozen() public {
        vm.startPrank(governor);

        vm.expectRevert(abi.encodePacked("a7"));
        proxyAsAdmin.unfreezeDiamond();
    }

    function test_ExecuteDiamondCut() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: Utils.getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.startPrank(governor);

        proxyAsAdmin.executeUpgrade(diamondCutData);

        bytes4[] memory gettersFacetSelectors = Utils.getGettersSelectors();
        for (uint256 i = 0; i < gettersFacetSelectors.length; i++) {
            bytes4 selector = gettersFacetSelectors[i];

            address addr = proxyAsGetters.facetAddress(selector);
            assertEq(addr, address(gettersFacet), "facet address mismatch");

            bool isFreezable = proxyAsGetters.isFunctionFreezable(selector);
            assertTrue(isFreezable, "isFreezable mismatch");
        }
    }

    function test_ExecutingSameProposalTwoTimes() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: Utils.getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.startPrank(governor);

        proxyAsAdmin.executeUpgrade(diamondCutData);
        proxyAsAdmin.executeUpgrade(diamondCutData);
    }
}
