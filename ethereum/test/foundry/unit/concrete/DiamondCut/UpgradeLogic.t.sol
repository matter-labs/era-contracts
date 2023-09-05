// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./_DiamondCut_Shared.t.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import "../../../../../cache/solpp-generated-contracts/zksync/facets/DiamondCut.sol";

contract UpgradeLogicTest is DiamondCutTest {
    DiamondProxy diamondProxy;
    DiamondInit diamondInit;
    DiamondCutFacet diamondCutFacet;
    DiamondCutFacet proxyAsDiamondCut;
    GettersFacet proxyAsGetters;
    address governor;
    address randomSigner;

    function getDiamondCutSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory dcSelectors = new bytes4[](8);
        dcSelectors[0] = diamondCutFacet.proposeTransparentUpgrade.selector;
        dcSelectors[1] = diamondCutFacet.proposeShadowUpgrade.selector;
        dcSelectors[2] = diamondCutFacet.cancelUpgradeProposal.selector;
        dcSelectors[3] = diamondCutFacet.securityCouncilUpgradeApprove.selector;
        dcSelectors[4] = diamondCutFacet.executeUpgrade.selector;
        dcSelectors[5] = diamondCutFacet.freezeDiamond.selector;
        dcSelectors[6] = diamondCutFacet.unfreezeDiamond.selector;
        dcSelectors[7] = diamondCutFacet.upgradeProposalHash.selector;
        return dcSelectors;
    }

    function setUp() public {
        governor = makeAddr("governor");
        randomSigner = makeAddr("randomSigner");

        diamondCutTestContract = new DiamondCutTestContract();
        diamondInit = new DiamondInit();
        diamondCutFacet = new DiamondCutFacet();
        gettersFacet = new GettersFacet();

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(diamondCutFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getDiamondCutSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getGettersSelectors()
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
            0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21,
            0,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0x70a0F165d6f8054d0d0CF8dFd4DD2005f0AF6B55,
            dummyVerifierParams,
            false,
            0x0100000000000000000000000000000000000000000000000000000000000000,
            0x0100000000000000000000000000000000000000000000000000000000000000,
            500000 // priority tx max L2 gas limit
        );

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitCalldata
        });

        diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        proxyAsDiamondCut = DiamondCutFacet(address(diamondProxy));
        proxyAsGetters = GettersFacet(address(diamondProxy));
    }

    function test_RevertWhen_EmergencyFreezeWhenUnauthurizedGovernor() public {
        vm.startPrank(randomSigner);

        vm.expectRevert(abi.encodePacked("1g"));
        proxyAsDiamondCut.freezeDiamond();
    }

    function test_RevertWhen_DoubleFreezingByGovernor() public {
        vm.startPrank(governor);

        proxyAsDiamondCut.freezeDiamond();

        vm.expectRevert(abi.encodePacked("a9"));
        proxyAsDiamondCut.freezeDiamond();
    }

    function test_RevertWhen_UnfreezingWhenNotFrozen() public {
        vm.startPrank(governor);

        vm.expectRevert(abi.encodePacked("a7"));
        proxyAsDiamondCut.unfreezeDiamond();
    }

    function test_RevertWhen_ExecutingUnapprovedProposalWHenDiamondStorageIsFrozen()
        public
    {
        vm.startPrank(governor);

        proxyAsDiamondCut.freezeDiamond();

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, 1);

        vm.expectRevert(abi.encodePacked("f3"));
        proxyAsDiamondCut.executeUpgrade(diamondCutData, 0);
    }

    function test_RevertWhen_ExecutingProposalWithDifferentInitAddress()
        public
    {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory proposedDiamondCutData = Diamond
            .DiamondCutData({
                facetCuts: facetCuts,
                initAddress: address(0),
                initCalldata: bytes("")
            });

        Diamond.DiamondCutData memory executedDiamondCutData = Diamond
            .DiamondCutData({
                facetCuts: facetCuts,
                initAddress: address(1),
                initCalldata: bytes("")
            });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        proxyAsDiamondCut.proposeTransparentUpgrade(
            proposedDiamondCutData,
            nextProposalId
        );

        vm.expectRevert(abi.encodePacked("a4"));
        proxyAsDiamondCut.executeUpgrade(executedDiamondCutData, 0);
    }

    function test_RevertWhen_ExecutingProposalWithDifferentFacetCut() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.FacetCut[] memory invalidFacetCuts = new Diamond.FacetCut[](1);
        invalidFacetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        Diamond.DiamondCutData memory invalidDiamondCutData = Diamond
            .DiamondCutData({
                facetCuts: invalidFacetCuts,
                initAddress: address(0),
                initCalldata: bytes("")
            });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);
        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );

        vm.expectRevert(abi.encodePacked("a4"));
        proxyAsDiamondCut.executeUpgrade(invalidDiamondCutData, 0);
    }

    function test_RevertWhen_CancelingEmptyProposal() public {
        bytes32 proposalHash = proxyAsGetters.getProposedUpgradeHash();

        vm.startPrank(governor);

        vm.expectRevert(abi.encodePacked("a3"));
        proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
    }

    function test_ProposeAndExecuteDiamondCut() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );

        proxyAsDiamondCut.executeUpgrade(diamondCutData, 0);

        bytes4[] memory gettersFacetSelectors = getGettersSelectors();
        for (uint256 i = 0; i < gettersFacetSelectors.length; i++) {
            bytes4 selector = gettersFacetSelectors[i];

            address addr = proxyAsGetters.facetAddress(selector);
            assertEq(addr, address(gettersFacet), "facet address mismatch");

            bool isFreezable = proxyAsGetters.isFunctionFreezable(selector);
            assertTrue(isFreezable, "isFreezable mismatch");
        }
    }

    function test_RevertWhen_ExecutingSameProposalTwoTimes() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );

        proxyAsDiamondCut.executeUpgrade(diamondCutData, 0);

        vm.expectRevert(abi.encodePacked("ab"));
        proxyAsDiamondCut.executeUpgrade(diamondCutData, 0);
    }

    function test_RevertWhen_ProposingAnAlreadyPropsedUpgrade() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );

        vm.expectRevert(abi.encodePacked("a8"));
        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );
    }

    function test_RevertWhen_ExecutingUnapprovedShadowUpgrade() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        bytes32 executingProposalHash = proxyAsDiamondCut.upgradeProposalHash(
            diamondCutData,
            nextProposalId,
            0
        );

        proxyAsDiamondCut.proposeShadowUpgrade(
            executingProposalHash,
            nextProposalId
        );

        vm.expectRevert(abi.encodePacked("av"));
        proxyAsDiamondCut.executeUpgrade(diamondCutData, 0);
    }

    function test_RevertWhen_ProposingShadowUpgradeWithWrongProposalId()
        public
    {
        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        vm.expectRevert(abi.encodePacked("ya"));
        proxyAsDiamondCut.proposeShadowUpgrade(
            bytes32("randomBytes32"),
            nextProposalId + 1
        );
    }

    function test_RevertWhen_ProposingTransparentUpgradeWithWrongProposalId()
        public
    {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 currentProposalId = uint40(
            proxyAsGetters.getCurrentProposalId()
        );

        vm.startPrank(governor);

        vm.expectRevert(abi.encodePacked("yb"));
        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            currentProposalId
        );
    }

    function test_RevertWhen_CancellingUpgradeProposalWithWrongHash() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );

        vm.expectRevert(abi.encodePacked("rx"));
        proxyAsDiamondCut.cancelUpgradeProposal(bytes32("randomBytes32"));
    }

    function test_RevertWhen_ExecutingTransparentUpgradeWithNonZeroSalt()
        public
    {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: getGettersSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        uint40 nextProposalId = uint40(
            proxyAsGetters.getCurrentProposalId() + 1
        );

        vm.startPrank(governor);

        proxyAsDiamondCut.proposeTransparentUpgrade(
            diamondCutData,
            nextProposalId
        );

        vm.expectRevert(abi.encodePacked("po"));
        proxyAsDiamondCut.executeUpgrade(
            diamondCutData,
            bytes32("randomBytes32")
        );
    }
}
