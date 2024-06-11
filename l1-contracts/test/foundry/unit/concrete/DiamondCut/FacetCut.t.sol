// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Utils} from "../Utils/Utils.sol";
import {DiamondCutTest} from "./_DiamondCut_Shared.t.sol";

import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract FacetCutTest is DiamondCutTest {
    MailboxFacet private mailboxFacet;
    ExecutorFacet private executorFacet1;
    ExecutorFacet private executorFacet2;

    uint256 eraChainId;

    function getExecutorSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = executorFacet1.commitBatches.selector;
        selectors[1] = executorFacet1.proveBatches.selector;
        selectors[2] = executorFacet1.executeBatches.selector;
        selectors[3] = executorFacet1.revertBatches.selector;
        return selectors;
    }

    function setUp() public {
        eraChainId = 9;
        diamondCutTestContract = new DiamondCutTestContract();
        mailboxFacet = new MailboxFacet(eraChainId);
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
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getGettersSelectors()
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

        uint256 numOfFacetsBefore = diamondCutTestContract.facetAddresses().length;

        diamondCutTestContract.diamondCut(diamondCutData);

        uint256 numOfFacetsAfter = diamondCutTestContract.facetAddresses().length;

        assertEq(numOfFacetsBefore + facetCuts.length, numOfFacetsAfter, "wrong number of facets added");
    }

    function test_RevertWhen_AddingFacetToOccupiedSelector() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getMailboxSelectors()
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
            selectors: Utils.getMailboxSelectors()
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
            selectors: Utils.getMailboxSelectors()
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
            selectors: Utils.getMailboxSelectors()
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
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: Utils.getMailboxSelectors()
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
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getMailboxSelectors()
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
            facet: address(executorFacet2),
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

        uint256 numOfFacetsAfterAdd = diamondCutTestContract.facetAddresses().length;

        Diamond.FacetCut[] memory facetCuts2 = new Diamond.FacetCut[](1);
        facetCuts2[0] = Diamond.FacetCut({
            facet: address(executorFacet2),
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

        uint256 numOfFacetsAfterReplace = diamondCutTestContract.facetAddresses().length;

        assertEq(numOfFacetsAfterAdd, numOfFacetsAfterReplace);
    }

    function test_RevertWhen_AddingFacetWithNoBytecode() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = 0x00000005;

        Diamond.FacetCut[] memory facetCuts1 = new Diamond.FacetCut[](1);
        facetCuts1[0] = Diamond.FacetCut({
            facet: address(1),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: selectors
        });

        Diamond.DiamondCutData memory diamondCutData1 = Diamond.DiamondCutData({
            facetCuts: facetCuts1,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("G"));
        diamondCutTestContract.diamondCut(diamondCutData1);
    }

    function test_RevertWhen_ReplacingFacetWithNoBytecode() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = 0x00000005;

        Diamond.FacetCut[] memory facetCuts1 = new Diamond.FacetCut[](1);
        facetCuts1[0] = Diamond.FacetCut({
            facet: address(1),
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: selectors
        });

        Diamond.DiamondCutData memory diamondCutData1 = Diamond.DiamondCutData({
            facetCuts: facetCuts1,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("K"));
        diamondCutTestContract.diamondCut(diamondCutData1);
    }

    function test_RevertWhen_AddingFacetWithDifferentFreezabilityThanExistingFacets() public {
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

    function test_RevertWhen_ReplacingFacetWithDifferentFreezabilityThanExistingFacets() public {
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
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(mailboxFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getMailboxSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        diamondCutTestContract.diamondCut(diamondCutData);
    }
}
