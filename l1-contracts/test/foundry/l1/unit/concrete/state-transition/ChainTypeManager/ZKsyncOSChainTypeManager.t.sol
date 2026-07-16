// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/ICTMRelease.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {
    ZeroAddress,
    GenesisBatchHashZero,
    GenesisBatchCommitmentIncorrect,
    GenesisUpgradeZero
} from "contracts/common/L1ContractErrors.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";

/// @notice From v32 the ZKsyncOS CTM validates genesis params by reading them from the genesis
///         `CTMRegistry` it is initialized with (not from an inline `ChainCreationParams`). These
///         tests mock that registry's `genesisParams` per case and assert the CTM enforces the
///         ZKsyncOS rules (genesis upgrade non-zero, batch hash non-zero, commitment == 1).
contract ZKsyncOSChainTypeManagerTest is UtilsCallMockerTest {
    using stdStorage for StdStorage;

    ZKsyncOSChainTypeManager internal chainTypeManager;
    ZKsyncOSChainTypeManager internal chainContractAddress;
    L1GenesisUpgrade internal genesisUpgradeContract;
    L1Bridgehub internal bridgehub;
    L1ChainAssetHandler internal chainAssetHandler;
    L1MessageRoot internal messageroot;
    address internal diamondInit;
    address internal interopCenterAddress;
    address internal governor;
    address internal admin;
    address internal baseToken;
    address internal sharedBridge;
    address internal validator;
    address internal serverNotifier;
    bytes32 internal baseTokenAssetId;
    uint256 chainId = 112;
    address internal testnetVerifier;

    uint256 internal constant MAX_NUMBER_OF_ZK_CHAINS = 10;

    function setUp() public {
        // Avoid block.timestamp == 0 to keep paused-deposits sentinel semantics stable in tests.
        vm.warp(1);

        interopCenterAddress = makeAddr("interopCenter");
        governor = makeAddr("governor");
        admin = makeAddr("admin");
        baseToken = makeAddr("baseToken");
        sharedBridge = makeAddr("sharedBridge");
        validator = makeAddr("validator");
        serverNotifier = makeAddr("serverNotifier");
        baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, baseToken);
        testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));

        bridgehub = new L1Bridgehub(governor, MAX_NUMBER_OF_ZK_CHAINS);
        chainAssetHandler = new L1ChainAssetHandler(governor, address(bridgehub));
        messageroot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(bridgehub), 1, address(chainAssetHandler))),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
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
        vm.prank(governor);
        chainAssetHandler.setAddresses();

        vm.startPrank(address(bridgehub));
        chainTypeManager = new ZKsyncOSChainTypeManager(
            address(bridgehub),
            interopCenterAddress,
            address(0),
            address(0)
        );
        diamondInit = address(new DiamondInit(false));
        genesisUpgradeContract = new L1GenesisUpgrade();
        vm.stopPrank();
    }

    /// @dev Mocks the (single) test genesis registry to return the given genesis params. These
    ///      tests only exercise `_setGenesisRegistry` validation and never create a chain, so only
    ///      `genesisParams` needs mocking.
    function _mockGenesisParams(
        address _genesisUpgrade,
        bytes32 _genesisBatchHash,
        bytes32 _genesisBatchCommitment,
        uint64 _genesisIndexRepeatedStorageChanges
    ) internal {
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(_genesisUpgrade, _genesisBatchHash, _genesisBatchCommitment, _genesisIndexRepeatedStorageChanges)
        );
        vm.mockCall(Utils.TEST_GENESIS_REGISTRY, abi.encodeWithSelector(ICTMRelease.validate.selector), bytes(""));
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.isZKsyncOS.selector),
            abi.encode(true)
        );
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.protocolVersion.selector),
            abi.encode(0)
        );
    }

    function _deployChainTypeManager() internal returns (ZKsyncOSChainTypeManager) {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            verifier: testnetVerifier,
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

    function _expectInitRevert(bytes4 _err) internal {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            verifier: testnetVerifier,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(_err);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }

    // ============================================================
    // Constructor tests
    // ============================================================

    function test_constructor() public {
        ZKsyncOSChainTypeManager ctm = new ZKsyncOSChainTypeManager(
            address(bridgehub),
            interopCenterAddress,
            address(0),
            address(0)
        );
        assertEq(ctm.BRIDGE_HUB(), address(bridgehub));
    }

    // ============================================================
    // Genesis params validation - GenesisBatchCommitmentIncorrect
    // ============================================================

    function test_RevertWhen_genesisBatchCommitmentNotOne() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), bytes32(uint256(0x02)), 0x01);
        _expectInitRevert(GenesisBatchCommitmentIncorrect.selector);
    }

    function test_RevertWhen_genesisBatchCommitmentZero() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), bytes32(0), 0x01);
        _expectInitRevert(GenesisBatchCommitmentIncorrect.selector);
    }

    // ============================================================
    // Genesis params validation - GenesisUpgradeZero
    // ============================================================

    function test_RevertWhen_genesisUpgradeIsZero() public {
        _mockGenesisParams(address(0), bytes32(uint256(0x01)), bytes32(uint256(0x01)), 0x01);
        _expectInitRevert(GenesisUpgradeZero.selector);
    }

    // ============================================================
    // Genesis params validation - GenesisBatchHashZero
    // ============================================================

    function test_RevertWhen_genesisBatchHashIsZero() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(0), bytes32(uint256(0x01)), 0x01);
        _expectInitRevert(GenesisBatchHashZero.selector);
    }

    // ============================================================
    // setNewVersionUpgrade tests
    // ============================================================

    function test_successful_setNewVersionUpgrade() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), bytes32(uint256(0x01)), 0x01);
        chainContractAddress = _deployChainTypeManager();

        // Mock migration paused check
        vm.mockCall(address(chainAssetHandler), abi.encodeWithSignature("migrationPaused()"), abi.encode(true));

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: diamondInit,
            initCalldata: ""
        });
        uint256 oldProtocolVersion = 0;
        uint256 oldProtocolVersionDeadline = block.timestamp + 100;
        uint256 newProtocolVersion = 1;

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(
            cutData,
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion,
            testnetVerifier
        );

        // Verify that the protocol version deadline was set
        assertEq(chainContractAddress.protocolVersionDeadline(oldProtocolVersion), oldProtocolVersionDeadline);
        // Verify that the new protocol version is set
        assertEq(chainContractAddress.protocolVersion(), newProtocolVersion);
        // Verify that the verifier is set for the new protocol version
        assertEq(chainContractAddress.protocolVersionVerifier(newProtocolVersion), testnetVerifier);
    }

    function test_RevertWhen_setNewVersionUpgradeNotOwner() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), bytes32(uint256(0x01)), 0x01);
        chainContractAddress = _deployChainTypeManager();

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: diamondInit,
            initCalldata: ""
        });
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
            newProtocolVersion,
            testnetVerifier
        );
    }

    // ============================================================
    // Successful initialization test
    // ============================================================

    function test_successful_initialization() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), bytes32(uint256(0x01)), 0x01);
        chainContractAddress = _deployChainTypeManager();

        assertEq(chainContractAddress.owner(), governor);
        assertEq(chainContractAddress.BRIDGE_HUB(), address(bridgehub));
    }

    // ============================================================
    // Fuzz tests
    // ============================================================

    function test_fuzz_RevertWhen_invalidGenesisBatchCommitment(bytes32 commitment) public {
        // Skip the valid case
        vm.assume(commitment != bytes32(uint256(1)));

        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), commitment, 0x01);
        _expectInitRevert(GenesisBatchCommitmentIncorrect.selector);
    }
}
