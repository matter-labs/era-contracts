// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {DiamondProxy} from "solpp/zksync/DiamondProxy.sol";
import {DiamondInit} from "solpp/zksync/DiamondInit.sol";
import {VerifierParams} from "solpp/zksync/Storage.sol";
import {Diamond} from "solpp/zksync/libraries/Diamond.sol";
import {AdminFacet} from "solpp/zksync/facets/Admin.sol";
import {Governance} from "solpp/governance/Governance.sol";

contract AdminTest is Test {
    DiamondProxy internal diamondProxy;
    address internal owner;
    address internal securityCouncil;
    address internal governor;
    AdminFacet internal adminFacet;
    AdminFacet internal proxyAsAdmin;

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
        owner = makeAddr("owner");
        securityCouncil = makeAddr("securityCouncil");
        governor = makeAddr("governor");
        DiamondInit diamondInit = new DiamondInit();

        VerifierParams memory dummyVerifierParams = VerifierParams({
            recursionNodeLevelVkHash: 0,
            recursionLeafLevelVkHash: 0,
            recursionCircuitsSetVksHash: 0
        });

        adminFacet = new AdminFacet();

        bytes memory diamondInitCalldata = abi.encodeWithSelector(
            diamondInit.initialize.selector,
            0x03752D8252d67f99888E741E3fB642803B29B155,
            governor,
            owner,
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

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(adminFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getAdminSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitCalldata
        });

        diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        proxyAsAdmin = AdminFacet(address(diamondProxy));
    }
}
