// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IServerNotifier} from "contracts/governance/IServerNotifier.sol";
import {DummyChainTypeManager} from "contracts/dev-contracts/test/DummyChainTypeManagerForServerNotifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DummyChainAssetHandler} from "contracts/dev-contracts/test/DummyChainAssetHandler.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IUpgradePreconditionChecker} from "contracts/upgrades/IUpgradePreconditionChecker.sol";
import {
    CutDataForProtocolVersionNotAvailable,
    InvalidProtocolVersion,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

// Isolates notifier behavior from any release-specific prerequisites.
contract UpgradePreconditionCheckerStub is IUpgradePreconditionChecker {
    bool public ready = true;

    function setReady(bool _ready) external {
        ready = _ready;
    }

    /// @inheritdoc IUpgradePreconditionChecker
    function checkUpgradePreconditions(uint256, address) external view {
        require(ready, "Upgrade not ready");
    }
}

contract ServerNotifierTest is Test {
    ServerNotifier internal serverNotifier;
    DummyChainTypeManager internal chainTypeManager;
    DummyBridgehub internal bridgehub;
    DummyChainAssetHandler internal chainAssetHandler;
    UpgradePreconditionCheckerStub internal checker;

    address internal owner;
    address internal chainAdmin;
    address internal chain;
    uint256 internal chainId;
    uint256 internal protocolVersion;

    function setUp() public {
        chainId = 1;
        protocolVersion = 42;
        owner = makeAddr("owner");
        chainAdmin = makeAddr("chainAdmin");
        chain = makeAddr("chainDiamond");
        checker = new UpgradePreconditionCheckerStub();

        // Set up mock bridgehub and chain asset handler
        bridgehub = new DummyBridgehub();
        chainAssetHandler = new DummyChainAssetHandler();
        bridgehub.setChainAssetHandler(address(chainAssetHandler));

        chainTypeManager = new DummyChainTypeManager();
        chainTypeManager.setBridgeHub(address(bridgehub));

        chainTypeManager.setChainAdmin(chainId, chainAdmin);
        chainTypeManager._setChainProtocolVersion(chainId, protocolVersion);
        chainTypeManager.setZKChain(chainId, chain);
        chainTypeManager.setUpgradeCutHash(protocolVersion, keccak256("upgradeCutHash"));

        ServerNotifier implementation = new ServerNotifier();

        ProxyAdmin proxyAdmin = new ProxyAdmin();

        bytes memory initData = abi.encodeWithSelector(ServerNotifier.initialize.selector, owner);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );

        serverNotifier = ServerNotifier(address(proxy));

        vm.prank(owner);
        serverNotifier.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));
    }

    function test_setUpgradeTimestampValidProtocolVersionSucceeds() public {
        uint deadline = block.timestamp + 7 days;

        chainTypeManager.setUpgradeCutHash(protocolVersion, keccak256("upgradeCutHash"));
        chainTypeManager.setProtocolVersionDeadline(protocolVersion, deadline);

        vm.startPrank(chainAdmin);
        vm.expectEmit(true, true, true, true, address(serverNotifier));
        emit IServerNotifier.UpgradeTimestampUpdated(chainId, protocolVersion, deadline);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);
        uint256 stored = serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion);
        assertEq(stored, deadline);
    }

    function test_setUpgradeTimestampCutDataForProtocolVersionNotAvailableReverts() public {
        chainTypeManager.setUpgradeCutHash(protocolVersion, bytes32(0));
        uint deadline = block.timestamp + 7 days;

        chainTypeManager.setProtocolVersionDeadline(protocolVersion, deadline);

        vm.startPrank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(CutDataForProtocolVersionNotAvailable.selector, protocolVersion));
        serverNotifier.setUpgradeTimestamp(chainId, deadline);
    }

    function test_setUpgradeTimestampInvalidCallerReverts() public {
        uint deadline = block.timestamp + 7 days;

        chainTypeManager.setProtocolVersionDeadline(protocolVersion, deadline);

        address alice = makeAddr("alice");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        serverNotifier.setUpgradeTimestamp(chainId, deadline);
    }

    function test_setChainTypeManagerSucceeds() public {
        DummyChainTypeManager newChainTypeManager = new DummyChainTypeManager();

        vm.startPrank(owner);
        serverNotifier.setChainTypeManager(IChainTypeManager(address(newChainTypeManager)));
        vm.stopPrank();

        assertEq(address(serverNotifier.chainTypeManager()), address(newChainTypeManager));
    }

    function test_setChainTypeManagerRevertsOnZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(ZeroAddress.selector);
        serverNotifier.setChainTypeManager(IChainTypeManager(address(0)));
        vm.stopPrank();
    }

    function test_setChainTypeManagerRevertsIfNotOwner() public {
        DummyChainTypeManager newChainTypeManager = new DummyChainTypeManager();
        address alice = makeAddr("alice");

        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        serverNotifier.setChainTypeManager(IChainTypeManager(address(newChainTypeManager)));
        vm.stopPrank();
    }

    function test_initializeRevertsOnZeroAddress() public {
        // Create an uninitialized proxy to test the ZeroAddress check
        ServerNotifier implementation = new ServerNotifier();
        ProxyAdmin newProxyAdmin = new ProxyAdmin();
        // Create proxy WITHOUT init data so it's not initialized yet
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(newProxyAdmin),
            "" // No init data - proxy is not initialized
        );
        ServerNotifier uninitializedNotifier = ServerNotifier(address(proxy));
        vm.expectRevert(ZeroAddress.selector);
        uninitializedNotifier.initialize(address(0));
    }

    function test_initializeCannotBeCalledTwice() public {
        // OZ's initializer modifier runs before reentrancyGuardInitializer and rejects re-initialization
        vm.expectRevert("Initializable: contract is already initialized");
        serverNotifier.initialize(owner);
    }

    function _registerChecker() internal {
        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);
    }

    /*//////////////////////////////////////////////////////////////
                        setUpgradePreconditionChecker
    //////////////////////////////////////////////////////////////*/

    function test_setCheckerRegistersAndEmits() public {
        uint256 deadline = block.timestamp + 7 days;
        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        address pendingOwner = makeAddr("pendingOwner");
        vm.prank(owner);
        serverNotifier.transferOwnership(pendingOwner);

        vm.expectEmit(true, false, false, true, address(serverNotifier));
        emit IServerNotifier.UpgradePreconditionCheckerSet(protocolVersion, address(checker));

        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);

        assertEq(address(serverNotifier.upgradePreconditionChecker(protocolVersion)), address(checker));
        assertEq(serverNotifier.owner(), owner);
        assertEq(serverNotifier.pendingOwner(), pendingOwner);
        assertEq(address(serverNotifier.chainTypeManager()), address(chainTypeManager));
        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    function test_setCheckerCanDeregister() public {
        _registerChecker();

        vm.expectEmit(true, false, false, true, address(serverNotifier));
        emit IServerNotifier.UpgradePreconditionCheckerSet(protocolVersion, address(0));

        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, IUpgradePreconditionChecker(address(0)));

        assertEq(address(serverNotifier.upgradePreconditionChecker(protocolVersion)), address(0));

        uint256 deadline = block.timestamp + 7 days;
        checker.setReady(false);
        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    function test_setCheckerRevertsIfNotOwner() public {
        vm.prank(chainAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);
    }

    /*//////////////////////////////////////////////////////////////
                    setUpgradeTimestamp with a checker
    //////////////////////////////////////////////////////////////*/

    function test_setUpgradeTimestampPassesWhenPreconditionsHold() public {
        _registerChecker();
        uint256 deadline = block.timestamp + 7 days;

        vm.expectCall(address(checker), abi.encodeCall(checker.checkUpgradePreconditions, (chainId, chain)));
        vm.expectEmit(true, true, true, true, address(serverNotifier));
        emit IServerNotifier.UpgradeTimestampUpdated(chainId, protocolVersion, deadline);

        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    function test_setUpgradeTimestampRevertsWhenPreconditionsFail() public {
        _registerChecker();
        checker.setReady(false);

        vm.prank(chainAdmin);
        vm.expectRevert("Upgrade not ready");
        serverNotifier.setUpgradeTimestamp(chainId, block.timestamp + 7 days);

        assertEq(
            serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion),
            0,
            "no timestamp may be recorded when scheduling reverts"
        );
    }

    function test_checkerForOtherVersionDoesNotAffectScheduling() public {
        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion + 1, checker);
        checker.setReady(false);

        uint256 deadline = block.timestamp + 7 days;
        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    function test_failedReschedulingPreservesTimestamp() public {
        _registerChecker();
        uint256 deadline = block.timestamp + 7 days;
        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        checker.setReady(false);
        vm.prank(chainAdmin);
        vm.expectRevert("Upgrade not ready");
        serverNotifier.setUpgradeTimestamp(chainId, deadline + 1 days);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }
}
