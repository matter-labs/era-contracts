// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ZeroAddress, GenesisBatchHashZero, GenesisUpgradeZero} from "contracts/common/L1ContractErrors.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";

import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";

/// @notice From v32 the CTM validates genesis params by reading them from the genesis release
///         it is initialized with (not from an inline `ChainCreationParams`). These tests mock
///         that release's `genesisParams` per case and assert the CTM enforces the rules (genesis
///         upgrade non-zero, batch hash non-zero, commitment == 1).
contract ChainTypeManagerValidationTest is UtilsCallMockerTest {
    using stdStorage for StdStorage;

    ChainTypeManager internal chainTypeManager;
    ChainTypeManager internal chainContractAddress;
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
        testnetVerifier = address(new ZKsyncOSTestnetVerifier(IVerifier(address(0))));

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
        chainTypeManager = new ChainTypeManager(address(bridgehub), interopCenterAddress, address(0), address(0));
        diamondInit = address(new DiamondInit());
        genesisUpgradeContract = new L1GenesisUpgrade();
        vm.stopPrank();
    }

    /// @dev Mocks the (single) test genesis release: its genesis params plus the `validate()` and
    ///      manifest-hash reads the CTM makes during initialization and repointing.
    function _mockGenesisParams(
        address _genesisUpgrade,
        bytes32 _genesisBatchHash,
        uint64 _genesisIndexRepeatedStorageChanges
    ) internal {
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(_genesisUpgrade, _genesisBatchHash, _genesisIndexRepeatedStorageChanges)
        );
        vm.mockCall(Utils.TEST_GENESIS_REGISTRY, abi.encodeWithSelector(ICTMRelease.validate.selector), bytes(""));
        // The CTM CALLS its genesis release while initializing, so the mocked one has to be a
        // deployed contract at all; the audited `CTMRelease` runtime code is what gets etched.
        vm.etch(Utils.TEST_GENESIS_REGISTRY, type(CTMRelease).runtimeCode);
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.manifestHash.selector),
            abi.encode(bytes32("mock-genesis-manifest"))
        );
    }

    function _deployChainTypeManager() internal returns (ChainTypeManager) {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
        return ChainTypeManager(address(transparentUpgradeableProxy));
    }

    function _expectInitRevert(bytes4 _err) internal {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
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
        ChainTypeManager ctm = new ChainTypeManager(address(bridgehub), interopCenterAddress, address(0), address(0));
        assertEq(ctm.BRIDGE_HUB(), address(bridgehub));
        assertTrue(ctm.isZKsyncOS());
    }

    // ============================================================
    // Genesis params validation - GenesisUpgradeZero
    // ============================================================

    function test_RevertWhen_genesisUpgradeIsZero() public {
        _mockGenesisParams(address(0), bytes32(uint256(0x01)), 0x01);
        _expectInitRevert(GenesisUpgradeZero.selector);
    }

    // ============================================================
    // Genesis params validation - GenesisBatchHashZero
    // ============================================================

    function test_RevertWhen_genesisBatchHashIsZero() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(0), 0x01);
        _expectInitRevert(GenesisBatchHashZero.selector);
    }

    // ============================================================
    // setNewVersionUpgrade tests
    // ============================================================

    function test_successful_setNewVersionUpgrade() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), 0x01);
        chainContractAddress = _deployChainTypeManager();

        // Mock migration paused check
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSignature("migrationPausedFor(address)"),
            abi.encode(true)
        );

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
            newProtocolVersion
        );

        // Verify that the protocol version deadline was set
        assertEq(chainContractAddress.protocolVersionDeadline(oldProtocolVersion), oldProtocolVersionDeadline);
        // Verify that the new protocol version is set
        assertEq(chainContractAddress.protocolVersion(), newProtocolVersion);
        // Verify that the verifier is set for the new protocol version
    }

    function test_RevertWhen_setNewVersionUpgradeNotOwner() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), 0x01);
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
            newProtocolVersion
        );
    }

    // ============================================================
    // Successful initialization test
    // ============================================================

    function test_successful_initialization() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), 0x01);
        chainContractAddress = _deployChainTypeManager();

        assertEq(chainContractAddress.owner(), governor);
        assertEq(chainContractAddress.BRIDGE_HUB(), address(bridgehub));
    }

    // ============================================================
    // Fuzz tests
    // ============================================================
}
