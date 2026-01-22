// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {DummyChainTypeManager} from "contracts/dev-contracts/test/DummyChainTypeManagerForServerNotifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {InvalidProtocolVersion, SlotOccupied, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract ServerNotifierTest is Test {
    ServerNotifier internal serverNotifier;
    DummyChainTypeManager internal chainTypeManager;

    address internal owner;
    address internal chainAdmin;
    uint256 internal chainId;

    event MigrateToGateway(uint256 indexed chainId);
    event MigrateFromGateway(uint256 indexed chainId);
    event UpgradeTimestampUpdated(uint256 indexed chainId, uint256 indexed protocolVersion, uint256 upgradeTimestamp);

    function setUp() public {
        chainId = 1;
        owner = makeAddr("owner");
        chainAdmin = makeAddr("chainAdmin");

        chainTypeManager = new DummyChainTypeManager();

        chainTypeManager.setChainAdmin(chainId, chainAdmin);

        ServerNotifier implementation = new ServerNotifier();

        ProxyAdmin proxyAdmin = new ProxyAdmin();

        bytes memory initData = abi.encodeWithSelector(ServerNotifier.initialize.selector, owner);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );

        serverNotifier = ServerNotifier(address(proxy));

        vm.startPrank(owner);
        serverNotifier.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));
    }

    function test_setUpgradeTimestampValidProtocolVersionSucceeds() public {
        uint protocolVersion = 42;
        uint deadline = block.timestamp + 7 days;

        chainTypeManager.setProtocolVersionDeadline(protocolVersion, deadline);

        vm.startPrank(chainAdmin);
        vm.expectEmit(true, true, true, true);
        emit UpgradeTimestampUpdated(chainId, protocolVersion, deadline);
        serverNotifier.setUpgradeTimestamp(chainId, protocolVersion, deadline);
        uint256 stored = serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion);
        assertEq(stored, deadline);
    }

    function test_setUpgradeTimestampInvalidProtocolVersionReverts() public {
        uint protocolVersion = 42;
        uint deadline = block.timestamp + 7 days;

        vm.startPrank(chainAdmin);
        vm.expectRevert(InvalidProtocolVersion.selector);
        serverNotifier.setUpgradeTimestamp(chainId, protocolVersion, deadline);
    }

    function test_setUpgradeTimestampInvalidCallerReverts() public {
        uint protocolVersion = 42;
        uint deadline = block.timestamp + 7 days;

        chainTypeManager.setProtocolVersionDeadline(protocolVersion, deadline);

        address alice = makeAddr("alice");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        serverNotifier.setUpgradeTimestamp(chainId, protocolVersion, deadline);
    }

    function test_migrateToGatewayEmitsEvent() public {
        chainTypeManager.setChainAdmin(chainId, chainAdmin);

        vm.startPrank(chainAdmin);
        vm.expectEmit(true, false, false, false);
        emit MigrateToGateway(chainId);
        serverNotifier.migrateToGateway(chainId);
        vm.stopPrank();
    }

    function test_migrateToGatewayInvalidCallerReverts() public {
        address alice = makeAddr("alice");

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        serverNotifier.migrateToGateway(chainId);
        vm.stopPrank();
    }

    function test_migrateFromGatewayEmitsEvent() public {
        chainTypeManager.setChainAdmin(chainId, chainAdmin);

        vm.startPrank(chainAdmin);
        vm.expectEmit(true, false, false, false);
        emit MigrateFromGateway(chainId);
        serverNotifier.migrateFromGateway(chainId);
        vm.stopPrank();
    }

    function test_migrateFromGatewayInvalidCallerReverts() public {
        address alice = makeAddr("alice");

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        serverNotifier.migrateFromGateway(chainId);
        vm.stopPrank();
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
        ServerNotifier newServerNotifier = new ServerNotifier();
        vm.expectRevert(ZeroAddress.selector);
        newServerNotifier.initialize(address(0));
    }

    function test_initializeCannotBeCalledTwice() public {
        vm.expectRevert(SlotOccupied.selector);
        serverNotifier.initialize(owner);
    }
}
