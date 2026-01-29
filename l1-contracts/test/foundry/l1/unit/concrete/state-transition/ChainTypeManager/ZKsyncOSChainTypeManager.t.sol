// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {IChainTypeManager, ChainCreationParams, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ZeroAddress, GenesisBatchHashZero, GenesisBatchCommitmentIncorrect, GenesisUpgradeZero} from "contracts/common/L1ContractErrors.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";

contract ZKsyncOSChainTypeManagerTest is UtilsCallMockerTest {
    using stdStorage for StdStorage;

    ZKsyncOSChainTypeManager internal chainTypeManager;
    ZKsyncOSChainTypeManager internal chainContractAddress;
    L1GenesisUpgrade internal genesisUpgradeContract;
    L1Bridgehub internal bridgehub;
    L1ChainAssetHandler internal chainAssetHandler;
    L1MessageRoot internal messageroot;
    address internal rollupL1DAValidator;
    address internal diamondInit;
    address internal interopCenterAddress;
    address internal governor;
    address internal admin;
    address internal baseToken;
    address internal sharedBridge;
    address internal validator;
    address internal l1Nullifier;
    address internal serverNotifier;
    bytes32 internal baseTokenAssetId;
    address internal newChainAdmin;
    uint256 l1ChainId = 5;
    uint256 chainId = 112;
    address internal testnetVerifier;
    bytes internal forceDeploymentsData = hex"";

    uint256 eraChainId = 9;
    uint256 internal constant MAX_NUMBER_OF_ZK_CHAINS = 10;

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        // Timestamp needs to be late enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);

        interopCenterAddress = makeAddr("interopCenter");
        governor = makeAddr("governor");
        admin = makeAddr("admin");
        baseToken = makeAddr("baseToken");
        sharedBridge = makeAddr("sharedBridge");
        validator = makeAddr("validator");
        l1Nullifier = makeAddr("l1Nullifier");
        serverNotifier = makeAddr("serverNotifier");
        newChainAdmin = makeAddr("chainadmin");
        baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, baseToken);
        testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));

        bridgehub = new L1Bridgehub(governor, MAX_NUMBER_OF_ZK_CHAINS);
        messageroot = new L1MessageRoot(address(bridgehub), 1);
        chainAssetHandler = new L1ChainAssetHandler(
            governor,
            address(bridgehub),
            address(0),
            address(messageroot),
            address(0),
            IL1Nullifier(address(0))
        );

        stdstore
            .target(address(messageroot))
            .sig(IL1MessageRoot.v31UpgradeChainBatchNumber.selector)
            .with_key(chainId)
            .checked_write(uint256(1));

        vm.prank(governor);
        bridgehub.setAddresses(
            sharedBridge,
            ICTMDeploymentTracker(address(0)),
            messageroot,
            address(chainAssetHandler),
            address(0)
        );

        vm.mockCall(
            address(sharedBridge),
            abi.encodeCall(L1AssetRouter.l2BridgeAddress, (chainId)),
            abi.encode(makeAddr("l2BridgeAddress"))
        );

        vm.startPrank(address(bridgehub));
        chainTypeManager = new ZKsyncOSChainTypeManager(address(bridgehub), interopCenterAddress, address(0));
        diamondInit = address(new DiamondInit(false));
        genesisUpgradeContract = new L1GenesisUpgrade();

        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new AdminFacet(block.chainid, RollupDAManager(address(0)), false)),
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: Utils.getAdminSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new ExecutorFacet(block.chainid)),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getExecutorSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new GettersFacet()),
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: Utils.getGettersSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(
                    new MailboxFacet(
                        block.chainid,
                        address(0),
                        IEIP7702Checker(makeAddr("eip7702Checker")),
                        false
                    )
                ),
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: Utils.getMailboxSelectors()
            })
        );
        vm.stopPrank();
    }

    function _deployChainTypeManager(
        ChainCreationParams memory chainCreationParams
    ) internal returns (ZKsyncOSChainTypeManager) {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
        return ZKsyncOSChainTypeManager(address(transparentUpgradeableProxy));
    }

    function getDiamondCutData(address _diamondInit) internal view returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(testnetVerifier);
        bytes memory initCalldata = abi.encode(initializeData);
        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    // ============================================================
    // Constructor tests
    // ============================================================

    function test_constructor() public {
        ZKsyncOSChainTypeManager ctm = new ZKsyncOSChainTypeManager(
            address(bridgehub),
            interopCenterAddress,
            address(0)
        );
        assertEq(ctm.BRIDGE_HUB(), address(bridgehub));
    }

    // ============================================================
    // setChainCreationParams - GenesisBatchCommitmentIncorrect tests
    // ============================================================

    function test_RevertWhen_genesisBatchCommitmentNotOne() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x02)), // Invalid: should be 1
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(GenesisBatchCommitmentIncorrect.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }

    function test_RevertWhen_genesisBatchCommitmentZero() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(0), // Invalid: should be 1
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(GenesisBatchCommitmentIncorrect.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }

    // ============================================================
    // validateChainCreationParams - GenesisUpgradeZero tests
    // ============================================================

    function test_RevertWhen_genesisUpgradeIsZero() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(0), // Invalid: should not be zero
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(GenesisUpgradeZero.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }

    // ============================================================
    // validateChainCreationParams - GenesisBatchHashZero tests
    // ============================================================

    function test_RevertWhen_genesisBatchHashIsZero() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(0), // Invalid: should not be zero
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(GenesisBatchHashZero.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }

    // ============================================================
    // setNewVersionUpgrade tests
    // ============================================================

    function test_successful_setNewVersionUpgrade() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        chainContractAddress = _deployChainTypeManager(chainCreationParams);

        Diamond.DiamondCutData memory cutData = getDiamondCutData(address(diamondInit));
        uint256 oldProtocolVersion = 0;
        uint256 oldProtocolVersionDeadline = block.timestamp + 100;
        uint256 newProtocolVersion = 1;

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(
            cutData,
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion
        );

        // Verify that the protocol version deadline was set
        assertEq(chainContractAddress.protocolVersionDeadline(oldProtocolVersion), oldProtocolVersionDeadline);
    }

    function test_RevertWhen_setNewVersionUpgradeNotOwner() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        chainContractAddress = _deployChainTypeManager(chainCreationParams);

        Diamond.DiamondCutData memory cutData = getDiamondCutData(address(diamondInit));
        uint256 oldProtocolVersion = 0;
        uint256 oldProtocolVersionDeadline = block.timestamp + 100;
        uint256 newProtocolVersion = 1;

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setNewVersionUpgrade(
            cutData,
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion
        );
    }

    // ============================================================
    // Successful initialization test
    // ============================================================

    function test_successful_initialization() public {
        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)), // Valid: exactly 1
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        chainContractAddress = _deployChainTypeManager(chainCreationParams);

        assertEq(chainContractAddress.owner(), governor);
        assertEq(chainContractAddress.BRIDGE_HUB(), address(bridgehub));
    }

    // ============================================================
    // Fuzz tests
    // ============================================================

    function test_fuzz_RevertWhen_invalidGenesisBatchCommitment(bytes32 commitment) public {
        // Skip the valid case
        vm.assume(commitment != bytes32(uint256(1)));

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: commitment,
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(GenesisBatchCommitmentIncorrect.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }
}
