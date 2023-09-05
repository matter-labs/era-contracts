// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../cache/solpp-generated-contracts/dev-contracts/test/DiamondCutTestContract.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Mailbox.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/Executor.sol";
import "../../cache/solpp-generated-contracts/dev-contracts/RevertFallback.sol";
import "../../cache/solpp-generated-contracts/dev-contracts/ReturnSomething.sol";
import "../../cache/solpp-generated-contracts/zksync/DiamondProxy.sol";
import "../../cache/solpp-generated-contracts/zksync/DiamondInit.sol";
import "../../cache/solpp-generated-contracts/zksync/facets/DiamondCut.sol";

contract DiamondProxyTest is Test {
    DiamondCutTestContract diamondCutTestContract;
    GettersFacet gettersFacet;

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](32);
        selectors[0] = gettersFacet.getVerifier.selector;
        selectors[1] = gettersFacet.getGovernor.selector;
        selectors[2] = gettersFacet.getPendingGovernor.selector;
        selectors[3] = gettersFacet.getTotalBlocksCommitted.selector;
        selectors[4] = gettersFacet.getTotalBlocksVerified.selector;
        selectors[5] = gettersFacet.getTotalBlocksExecuted.selector;
        selectors[6] = gettersFacet.getTotalPriorityTxs.selector;
        selectors[7] = gettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = gettersFacet.getPriorityQueueSize.selector;
        selectors[9] = gettersFacet.priorityQueueFrontOperation.selector;
        selectors[10] = gettersFacet.isValidator.selector;
        selectors[11] = gettersFacet.l2LogsRootHash.selector;
        selectors[12] = gettersFacet.storedBlockHash.selector;
        selectors[13] = gettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[14] = gettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = gettersFacet.getVerifierParams.selector;
        selectors[16] = gettersFacet.isDiamondStorageFrozen.selector;
        selectors[17] = gettersFacet.getSecurityCouncil.selector;
        selectors[18] = gettersFacet.getUpgradeProposalState.selector;
        selectors[19] = gettersFacet.getProposedUpgradeHash.selector;
        selectors[20] = gettersFacet.getProposedUpgradeTimestamp.selector;
        selectors[21] = gettersFacet.getCurrentProposalId.selector;
        selectors[22] = gettersFacet.isApprovedBySecurityCouncil.selector;
        selectors[23] = gettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[24] = gettersFacet.getAllowList.selector;
        selectors[25] = gettersFacet.isEthWithdrawalFinalized.selector;
        selectors[26] = gettersFacet.facets.selector;
        selectors[27] = gettersFacet.facetFunctionSelectors.selector;
        selectors[28] = gettersFacet.facetAddresses.selector;
        selectors[29] = gettersFacet.facetAddress.selector;
        selectors[30] = gettersFacet.isFunctionFreezable.selector;
        selectors[31] = gettersFacet.isFacetFreezable.selector;
        return selectors;
    }
}

contract FacetCutTest is DiamondProxyTest {
    MailboxFacet mailboxFacet;
    ExecutorFacet executorFacet1;
    ExecutorFacet executorFacet2;

    function getMailboxSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = mailboxFacet.proveL2MessageInclusion.selector;
        selectors[1] = mailboxFacet.proveL2LogInclusion.selector;
        selectors[2] = mailboxFacet.proveL1ToL2TransactionStatus.selector;
        selectors[3] = mailboxFacet.finalizeEthWithdrawal.selector;
        selectors[4] = mailboxFacet.requestL2Transaction.selector;
        selectors[5] = mailboxFacet.l2TransactionBaseCost.selector;
        return selectors;
    }

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = executorFacet1.commitBlocks.selector;
        selectors[1] = executorFacet1.proveBlocks.selector;
        selectors[2] = executorFacet1.executeBlocks.selector;
        selectors[3] = executorFacet1.revertBlocks.selector;
        return selectors;
    }

    function setUp() public {
        diamondCutTestContract = new DiamondCutTestContract();
        mailboxFacet = new MailboxFacet();
        gettersFacet = new GettersFacet();
        executorFacet1 = new ExecutorFacet();
        executorFacet2 = new ExecutorFacet();
    }

    function test_AddingFacetsToFreeSelectors() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getGettersSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(executorFacet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getExecutorSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: 0x0000000000000000000000000000000000000000,
            initCalldata: bytes("")
        });

        uint256 numOfFacetsBefore = diamondCutTestContract
            .facetAddresses()
            .length;

        diamondCutTestContract.diamondCut(diamondCutData);

        uint256 numOfFacetsAfter = diamondCutTestContract
            .facetAddresses()
            .length;

        assertEq(
            numOfFacetsBefore + facetCuts.length,
            numOfFacetsAfter,
            "wrong number of facets added"
        );
    }

    function test_RevertWhen_AddingFacetToOccupiedSelector() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData);

        vm.expectRevert(abi.encodePacked("J"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_AddingFacetWithZeroAddress() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("G"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_ReplacingFacetFromFreeSelector() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("L"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_RemovingFacetFromFreeSelector() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("a1"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_ReplaceFacetForOccupiedSelector() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(executorFacet1),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getExecutorSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(executorFacet2),
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: getExecutorSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RemovingFacetFromOccupiedSelector() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_AddingFacetAfterRemoving() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_ReplacingASelectorFacetWithItself() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = 0x00000005;

        Diamond.FacetCut[] memory facetCuts1 = new Diamond.FacetCut[](1);
        facetCuts1[0] = Diamond.FacetCut({
            facet: address(0x000000000000000000000000000000000000000A),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors
        });

        Diamond.DiamondCutData memory diamondCutData1 = Diamond.DiamondCutData({
            facetCuts: facetCuts1,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData1);

        uint256 numOfFacetsAfterAdd = diamondCutTestContract
            .facetAddresses()
            .length;

        Diamond.FacetCut[] memory facetCuts2 = new Diamond.FacetCut[](1);
        facetCuts2[0] = Diamond.FacetCut({
            facet: address(0x000000000000000000000000000000000000000A),
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory diamondCutData2 = Diamond.DiamondCutData({
            facetCuts: facetCuts2,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData2);

        uint256 numOfFacetsAfterReplace = diamondCutTestContract
            .facetAddresses()
            .length;

        assertEq(numOfFacetsAfterAdd, numOfFacetsAfterReplace);
    }

    function test_RevertWhen_AddingFacetWithDifferentFreezabilityThanExistingFacets()
        public
    {
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = 0x00000001;

        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = 0x00000002;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors1
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors2
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("J1"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_ReplacingFacetWithDifferentFreezabilityThanExistingFacets()
        public
    {
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = 0x00000001;
        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = 0x00000002;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors1
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors2
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: selectors2
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("J1"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_ChangingFacetFreezability() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: getMailboxSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData);
    }
}

contract InitializationTest is DiamondProxyTest {
    address revertFallbackAddress;
    address returnSomethingAddress;
    address signerAddress; // EOA

    function setUp() public {
        signerAddress = makeAddr("signer");
        diamondCutTestContract = new DiamondCutTestContract();
        revertFallbackAddress = address(new RevertFallback());
        returnSomethingAddress = address(new ReturnSomething());
    }

    function test_RevertWhen_DelegateCallToFailedContract() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: revertFallbackAddress,
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("I"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_ReverWhen_DelegateCallToEOA() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: signerAddress,
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("lp"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_InitializingDiamondCutWithZeroAddressAndNonZeroData()
        public
    {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("0x11")
        });

        vm.expectRevert(abi.encodePacked("H"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_DelegateCallToAContractWithWrongReturn() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: returnSomethingAddress,
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("lp1"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }
}

contract UpgradeLogicTest is DiamondProxyTest {
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
