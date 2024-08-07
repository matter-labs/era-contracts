// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DiamondCutTest} from "test/foundry/unit/concrete/DiamondCut/_DiamondCut_Shared.t.sol";

import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Utils} from "test/foundry/unit/concrete/Utils/Utils.sol";
import {InitializeData} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DummyStateTransitionManager} from "contracts/dev-contracts/test/DummyStateTransitionManager.sol";
import {MockERC20} from "lib/forge-std/src/mocks/MockERC20.sol";

contract ProxyTest is DiamondCutTest {
    DiamondProxy private diamondProxy;
    DiamondInit private diamondInit;
    AdminFacet private adminFacet;
    AdminFacet private proxyAsAdmin;
    GettersFacet private proxyAsGetters;
    ExecutorFacet private executorFacet;
    MailboxFacet private mailboxFacet;
    address private admin;
    address private stateTransitionManager;
    address private randomSigner;

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = adminFacet.setPendingAdmin.selector;
        selectors[1] = adminFacet.acceptAdmin.selector;
        selectors[2] = adminFacet.setValidator.selector;
        selectors[3] = adminFacet.setPorterAvailability.selector;
        selectors[4] = adminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[5] = adminFacet.changeFeeParams.selector;
        selectors[6] = adminFacet.setTokenMultiplier.selector;
        selectors[7] = adminFacet.upgradeChainFromVersion.selector;
        selectors[8] = adminFacet.executeUpgrade.selector;
        selectors[9] = adminFacet.freezeDiamond.selector;
        selectors[10] = adminFacet.unfreezeDiamond.selector;
        return selectors;
    }

    function setUp() public {
        admin = makeAddr("admin");
        stateTransitionManager = address(new DummyStateTransitionManager());
        randomSigner = makeAddr("randomSigner");

        diamondCutTestContract = new DiamondCutTestContract();
        diamondInit = new DiamondInit();
        adminFacet = new AdminFacet();
        gettersFacet = new GettersFacet();
        executorFacet = new ExecutorFacet();

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(adminFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: getAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(gettersFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getGettersSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(executorFacet),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getExecutorSelectors()
        });

        VerifierParams memory dummyVerifierParams = VerifierParams({
            recursionNodeLevelVkHash: 0,
            recursionLeafLevelVkHash: 0,
            recursionCircuitsSetVksHash: 0
        });

        InitializeData memory params = InitializeData({
            chainId: 1,
            bridgehub: makeAddr("bridgehub"),
            stateTransitionManager: stateTransitionManager,
            protocolVersion: 0,
            admin: admin,
            validatorTimelock: makeAddr("validatorTimelock"),
            baseToken: makeAddr("baseToken"),
            baseTokenBridge: makeAddr("baseTokenBridge"),
            storedBatchZero: bytes32(0),
            verifier: IVerifier(0x03752D8252d67f99888E741E3fB642803B29B155), // verifier
            verifierParams: dummyVerifierParams,
            l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            priorityTxMaxGasLimit: 500000,
            feeParams: FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            }),
            blobVersionedHashRetriever: makeAddr("blobVersionedHashRetriver")
        });

        bytes memory diamondInitCalldata = abi.encodeWithSelector(diamondInit.initialize.selector, params);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitCalldata
        });

        diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        proxyAsAdmin = AdminFacet(address(diamondProxy));
        proxyAsGetters = GettersFacet(address(diamondProxy));
    }

    function test_checkAddSelector() public {
        bytes4[] memory gettersSelectors = Utils.getGettersSelectors();
        for (uint256 i = 0; i < gettersSelectors.length; i++) {
            address addr = proxyAsGetters.facetAddress(gettersSelectors[i]);
            bool isFreezable = proxyAsGetters.isFunctionFreezable(gettersSelectors[i]);
            assertEq(addr, address(gettersFacet));
            assertFalse(isFreezable);
        }

        bytes4[] memory adminSelectors = getAdminSelectors();
        for (uint256 i = 0; i < adminSelectors.length; i++) {
            address addr = proxyAsGetters.facetAddress(adminSelectors[i]);
            bool isFreezable = proxyAsGetters.isFunctionFreezable(adminSelectors[i]);
            assertEq(addr, address(adminFacet));
            assertFalse(isFreezable);
        }
    }

    function test_rejectNonAddedSelector() public {
        mailboxFacet = new MailboxFacet(1);
        bytes4[] memory mailboxSelectors = Utils.getMailboxSelectors();
        vm.expectRevert(abi.encodePacked("F"));
        (bool success, ) = address(diamondProxy).call(abi.encode(mailboxSelectors[0]));
        assertTrue(success);
    }

    function test_rejectDataWithNoSelectors() public {
        string memory dataWithoutSelector = "0x112";
        vm.expectRevert(abi.encodePacked("Ut"));
        (bool success, ) = address(diamondProxy).call("1");
        assertTrue(success);
    }

    function test_freezeDiamondStorage() public {
        vm.startBroadcast(address(stateTransitionManager));
        proxyAsAdmin.freezeDiamond();
        vm.stopBroadcast();

        bool isFrozen = proxyAsGetters.isDiamondStorageFrozen();

        assertTrue(isFrozen);
    }

    function test_executingProposalWhenStorageIsFrozen() public {
        vm.startBroadcast(address(stateTransitionManager));
        proxyAsAdmin.freezeDiamond();
        vm.stopBroadcast();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = adminFacet.setTransactionFilterer.selector;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(adminFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: 0x0000000000000000000000000000000000000000,
            initCalldata: ""
        });

        bytes4[] memory adminSelectors = Utils.getAdminSelectors();
        vm.startBroadcast(address(stateTransitionManager));
        (bool success, ) = address(diamondProxy).call(abi.encodeWithSelector(adminSelectors[8], diamondCutData));
        vm.stopBroadcast();
        assertTrue(success);
    }

    function test_callFunctionWhenStorageIsFrozen() public {
        bytes4[] memory executorSelectors = Utils.getExecutorSelectors();

        vm.startBroadcast(address(stateTransitionManager));
        proxyAsAdmin.freezeDiamond();
        vm.stopBroadcast();

        vm.expectRevert(abi.encodePacked("q1"));
        (bool success, ) = address(diamondProxy).call(abi.encode(executorSelectors[3]));

        assertTrue(success);
    }

    function test_callUnfreezableFacetWhenStorageIsFrozen() public {
        vm.startBroadcast(address(stateTransitionManager));
        proxyAsAdmin.freezeDiamond();
        vm.stopBroadcast();

        bytes4[] memory gettersSelectors = Utils.getGettersSelectors();
        (bool success, ) = address(diamondProxy).call(abi.encode(gettersSelectors[0]));

        assertTrue(success);
    }
}
