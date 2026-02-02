// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DiamondCutTest} from "./_DiamondCut_Shared.t.sol";

import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {DiamondInit, InitializeData} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {FeeParams, PubdataPricingMode, VerifierParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Utils} from "../Utils/Utils.sol";
import {DummyChainTypeManager} from "contracts/dev-contracts/test/DummyChainTypeManager.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {DiamondAlreadyFrozen, DiamondNotFrozen, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";

contract UpgradeLogicTest is DiamondCutTest {
    DiamondProxy private diamondProxy;
    DiamondInit private diamondInit;
    AdminFacet private adminFacet;
    AdminFacet private proxyAsAdmin;
    GettersFacet private proxyAsGetters;
    PermissionlessValidator private permissionlessValidator;
    address interopCenter = makeAddr("interopCenter");
    address private admin;
    address private chainTypeManager;
    address private randomSigner;
    bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(1, (makeAddr("baseToken")));

    function getAdminSelectors() private view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        uint256 i = 0;
        selectors[i++] = adminFacet.setPendingAdmin.selector;
        selectors[i++] = adminFacet.acceptAdmin.selector;
        selectors[i++] = adminFacet.setValidator.selector;
        selectors[i++] = adminFacet.setPorterAvailability.selector;
        selectors[i++] = adminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = adminFacet.changeFeeParams.selector;
        selectors[i++] = adminFacet.setTokenMultiplier.selector;
        selectors[i++] = adminFacet.upgradeChainFromVersion.selector;
        selectors[i++] = adminFacet.executeUpgrade.selector;
        selectors[i++] = adminFacet.freezeDiamond.selector;
        selectors[i++] = adminFacet.unfreezeDiamond.selector;
        return selectors;
    }

    function setUp() public {
        admin = makeAddr("admin");
        chainTypeManager = address(new DummyChainTypeManager());
        randomSigner = makeAddr("randomSigner");
        DummyBridgehub dummyBridgehub = new DummyBridgehub();

        diamondCutTestContract = new DiamondCutTestContract();
        diamondInit = new DiamondInit(false);
        adminFacet = new AdminFacet(block.chainid, RollupDAManager(address(0)));
        gettersFacet = new GettersFacet();
        permissionlessValidator = new PermissionlessValidator();

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

        InitializeData memory params = InitializeData({
            // TODO REVIEW
            chainId: 1,
            bridgehub: address(dummyBridgehub),
            chainTypeManager: chainTypeManager,
            interopCenter: interopCenter,
            protocolVersion: 0,
            admin: admin,
            validatorTimelock: makeAddr("validatorTimelock"),
            baseTokenAssetId: baseTokenAssetId,
            storedBatchZero: bytes32(0),
            // genesisBatchHash: 0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21,
            // genesisIndexRepeatedStorageChanges: 0,
            // genesisBatchCommitment: bytes32(0),
            verifier: IVerifier(0x03752D8252d67f99888E741E3fB642803B29B155), // verifier
            // zkPorterIsAvailable: false,
            l2BootloaderBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            l2DefaultAccountBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            l2EvmEmulatorBytecodeHash: 0x0100000000000000000000000000000000000000000000000000000000000000,
            // initialProtocolVersion: 0,
            permissionlessValidator: address(permissionlessValidator)
        });

        bytes memory diamondInitCalldata = abi.encodeWithSelector(diamondInit.initialize.selector, params);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitCalldata
        });

        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), baseTokenAssetId);
        diamondProxy = new DiamondProxy(block.chainid, diamondCutData);
        proxyAsAdmin = AdminFacet(address(diamondProxy));
        proxyAsGetters = GettersFacet(address(diamondProxy));
    }

    function test_RevertWhen_EmergencyFreezeWhenUnauthorizedGovernor() public {
        vm.startPrank(randomSigner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        proxyAsAdmin.freezeDiamond();
    }

    function test_RevertWhen_DoubleFreezingByCTM() public {
        vm.startPrank(chainTypeManager);

        proxyAsAdmin.freezeDiamond();

        vm.expectRevert(DiamondAlreadyFrozen.selector);
        proxyAsAdmin.freezeDiamond();
    }

    function test_RevertWhen_UnfreezingWhenNotFrozen() public {
        vm.startPrank(chainTypeManager);

        vm.expectRevert(DiamondNotFrozen.selector);
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

        vm.startPrank(chainTypeManager);

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

        vm.startPrank(chainTypeManager);

        proxyAsAdmin.executeUpgrade(diamondCutData);
        proxyAsAdmin.executeUpgrade(diamondCutData);
    }
}
