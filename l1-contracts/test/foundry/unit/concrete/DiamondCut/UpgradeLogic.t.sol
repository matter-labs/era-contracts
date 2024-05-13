// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DiamondCutTest} from "./_DiamondCut_Shared.t.sol";

import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Utils} from "../Utils/Utils.sol";
import {InitializeData} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DummyStateTransitionManager} from "contracts/dev-contracts/test/DummyStateTransitionManager.sol";

contract UpgradeLogicTest is DiamondCutTest {
    DiamondProxy private diamondProxy;
    DiamondInit private diamondInit;
    AdminFacet private adminFacet;
    AdminFacet private proxyAsAdmin;
    GettersFacet private proxyAsGetters;
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

        InitializeData memory params = InitializeData({
            // TODO REVIEW
            chainId: 1,
            bridgehub: makeAddr("bridgehub"),
            stateTransitionManager: stateTransitionManager,
            protocolVersion: 0,
            admin: admin,
            validatorTimelock: makeAddr("validatorTimelock"),
            baseToken: makeAddr("baseToken"),
            baseTokenBridge: makeAddr("baseTokenBridge"),
            storedBatchZero: bytes32(0),
            // genesisBatchHash: 0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21,
            // genesisIndexRepeatedStorageChanges: 0,
            // genesisBatchCommitment: bytes32(0),
            verifier: IVerifier(0x03752D8252d67f99888E741E3fB642803B29B155), // verifier
            verifierParams: dummyVerifierParams,
            // zkPorterIsAvailable: false,
            l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            priorityTxMaxGasLimit: 500000, // priority tx max L2 gas limit
            // initialProtocolVersion: 0,
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

    function test_RevertWhen_EmergencyFreezeWhenUnauthorizedGovernor() public {
        vm.startPrank(randomSigner);

        vm.expectRevert(abi.encodePacked("Hyperchain: not state transition manager"));
        proxyAsAdmin.freezeDiamond();
    }

    function test_RevertWhen_DoubleFreezingBySTM() public {
        vm.startPrank(stateTransitionManager);

        proxyAsAdmin.freezeDiamond();

        vm.expectRevert(abi.encodePacked("a9"));
        proxyAsAdmin.freezeDiamond();
    }

    function test_RevertWhen_UnfreezingWhenNotFrozen() public {
        vm.startPrank(stateTransitionManager);

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

        vm.startPrank(stateTransitionManager);

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

        vm.startPrank(stateTransitionManager);

        proxyAsAdmin.executeUpgrade(diamondCutData);
        proxyAsAdmin.executeUpgrade(diamondCutData);
    }
}
