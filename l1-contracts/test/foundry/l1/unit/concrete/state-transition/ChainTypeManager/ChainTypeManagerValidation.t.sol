// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IManifestHash} from "contracts/upgrades/registry/objects/IManifestHash.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

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
import {GenesisBatchHashZero, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";

import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";

/// @notice Construction, initialization and version-edge validation of a CTM over a mocked genesis
///         release. A codeless genesis upgrade is the release's `validate()` to refuse, so it is
///         tested on `CTMRelease` and, through the CTM, in `Initialize.t.sol` with real releases.
contract ChainTypeManagerValidationTest is UtilsCallMockerTest {
    using stdStorage for StdStorage;

    ChainTypeManager internal chainTypeManager;
    ChainTypeManager internal chainContractAddress;
    L1GenesisUpgrade internal genesisUpgradeContract;
    L1Bridgehub internal bridgehub;
    L1ChainAssetHandler internal chainAssetHandler;
    L1MessageRoot internal messageroot;
    address internal diamondInit;
    address internal governor;
    address internal admin;
    address internal baseToken;
    address internal sharedBridge;
    address internal validator;
    address internal serverNotifier;
    address internal permissionlessValidator;
    bytes32 internal baseTokenAssetId;
    uint256 internal chainId = 112;
    address internal testnetVerifier;

    uint256 internal constant MAX_NUMBER_OF_ZK_CHAINS = 10;

    function setUp() public {
        // Avoid block.timestamp == 0 to keep paused-deposits sentinel semantics stable in tests.
        vm.warp(1);

        governor = makeAddr("governor");
        admin = makeAddr("admin");
        baseToken = makeAddr("baseToken");
        sharedBridge = makeAddr("sharedBridge");
        validator = makeAddr("validator");
        serverNotifier = makeAddr("serverNotifier");
        permissionlessValidator = makeAddr("permissionlessValidator");
        baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, baseToken);
        testnetVerifier = address(new ZKsyncOSTestnetVerifier(IVerifier(address(0))));

        bridgehub = new L1Bridgehub(governor, MAX_NUMBER_OF_ZK_CHAINS);
        chainAssetHandler = new L1ChainAssetHandler(governor, address(bridgehub));
        messageroot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(bridgehub), address(chainAssetHandler))),
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
        chainTypeManager = new ChainTypeManager(address(bridgehub), address(0), permissionlessValidator, address(0));
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
        // The CTM starts at its genesis release's version (0 here).
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.protocolVersion.selector),
            abi.encode(uint256(0))
        );
        // The CTM CALLS its genesis release while initializing, so the mocked one has to be a
        // deployed contract at all; the audited `CTMRelease` runtime code is what gets etched.
        vm.etch(Utils.TEST_GENESIS_REGISTRY, type(CTMRelease).runtimeCode);
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(IManifestHash.manifestHash.selector),
            abi.encode(bytes32("mock-genesis-manifest"))
        );
    }

    /// @dev A second mocked release, of `_protocolVersion`: what a cut-taking edge names and installs.
    function _releaseAt(uint256 _protocolVersion) internal returns (address release) {
        release = makeAddr(string.concat("release-", vm.toString(_protocolVersion)));
        vm.etch(release, type(CTMRelease).runtimeCode);
        vm.mockCall(release, abi.encodeWithSelector(ICTMRelease.validate.selector), bytes(""));
        vm.mockCall(
            release,
            abi.encodeWithSelector(ICTMRelease.protocolVersion.selector),
            abi.encode(_protocolVersion)
        );
        vm.mockCall(
            release,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(address(genesisUpgradeContract), bytes32(uint256(0x01)), uint64(0x01))
        );
    }

    function _deployChainTypeManager() internal returns (ChainTypeManager) {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
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

    /// @dev The genesis release is where the CTM reads its initial version from, so it is
    ///      refused before anything is read from it.
    function test_RevertWhen_initializedWithoutARelease() public {
        vm.startPrank(address(bridgehub));
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            currentRelease: address(0),
            serverNotifier: serverNotifier
        });
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        vm.stopPrank();
    }

    /// @dev A proxy over the CTM implementation that nobody has initialized yet, so a test can
    ///      call `initialize` itself and inspect the proxy after a refused call.
    function _uninitializedProxy() internal returns (ChainTypeManager) {
        return ChainTypeManager(address(new TransparentUpgradeableProxy(address(chainTypeManager), admin, "")));
    }

    function _initializeData() internal view returns (ChainTypeManagerInitializeData memory) {
        return
            ChainTypeManagerInitializeData({
                owner: governor,
                validatorTimelock: validator,
                currentRelease: Utils.TEST_GENESIS_REGISTRY,
                serverNotifier: serverNotifier
            });
    }

    /// @dev Asserts that a refused `initialize` left the proxy as it was.
    function _assertUninitialized(ChainTypeManager _ctm) internal view {
        assertEq(_ctm.owner(), address(0), "no owner");
        assertEq(_ctm.validatorTimelockPostV29(), address(0), "no validator timelock");
        assertEq(_ctm.serverNotifierAddress(), address(0), "no server notifier");
        assertEq(_ctm.currentRelease(), address(0), "no release");
    }

    function test_RevertWhen_initializedWithAZeroValidatorTimelock() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), 0x01);
        ChainTypeManager ctm = _uninitializedProxy();
        ChainTypeManagerInitializeData memory data = _initializeData();
        data.validatorTimelock = address(0);

        vm.expectRevert(ZeroAddress.selector);
        ctm.initialize(data);

        _assertUninitialized(ctm);
    }

    function test_RevertWhen_initializedWithAZeroServerNotifier() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(uint256(0x01)), 0x01);
        ChainTypeManager ctm = _uninitializedProxy();
        ChainTypeManagerInitializeData memory data = _initializeData();
        data.serverNotifier = address(0);

        vm.expectRevert(ZeroAddress.selector);
        ctm.initialize(data);

        _assertUninitialized(ctm);
    }

    /// @dev Every chain created from a release with a zero genesis batch hash would get an unusable
    ///      batch zero. A real `CTMRelease` refuses one at construction, so its `genesisParams()`
    ///      is mocked here to isolate the CTM's own check from the release's.
    function test_RevertWhen_genesisBatchHashIsZero() public {
        _mockGenesisParams(address(genesisUpgradeContract), bytes32(0), 0x01);
        ChainTypeManager ctm = _uninitializedProxy();

        vm.expectRevert(GenesisBatchHashZero.selector);
        ctm.initialize(_initializeData());

        _assertUninitialized(ctm);
    }

    // ============================================================
    // Constructor tests
    // ============================================================

    function test_constructor() public {
        ChainTypeManager ctm = new ChainTypeManager(
            address(bridgehub),
            address(0),
            permissionlessValidator,
            address(0)
        );
        assertEq(ctm.BRIDGE_HUB(), address(bridgehub));
        assertEq(ctm.PERMISSIONLESS_VALIDATOR(), permissionlessValidator);
        assertTrue(ctm.isZKsyncOS());
    }

    /// @dev Every chain an L1 CTM creates stores its permissionless validator, the only settler of
    ///      a chain in priority mode.
    function test_RevertWhen_anL1CTMIsConstructedWithoutAPermissionlessValidator() public {
        vm.expectRevert(ZeroAddress.selector);
        new ChainTypeManager(address(bridgehub), address(0), address(0), address(0));
    }

    /// @dev Priority mode exists on L1 only, so a Gateway CTM is constructed without one.
    function test_aGatewayCTMNeedsNoPermissionlessValidator() public {
        ChainTypeManager ctm = new ChainTypeManager(L2_BRIDGEHUB_ADDR, address(0), address(0), address(0));
        assertEq(ctm.BRIDGE_HUB(), L2_BRIDGEHUB_ADDR);
        assertEq(ctm.PERMISSIONLESS_VALIDATOR(), address(0));
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
        address newRelease = _releaseAt(newProtocolVersion);

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(cutData, oldProtocolVersion, oldProtocolVersionDeadline, newRelease);
        assertEq(chainContractAddress.currentRelease(), newRelease, "the edge installs the release of its version");

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
        address newRelease = _releaseAt(1);

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setNewVersionUpgrade(cutData, oldProtocolVersion, oldProtocolVersionDeadline, newRelease);
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
