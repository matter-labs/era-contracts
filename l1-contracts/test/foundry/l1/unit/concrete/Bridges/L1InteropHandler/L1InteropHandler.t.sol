// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropHandler} from "contracts/bridge/L1InteropHandler.sol";
import {IL1InteropHandler} from "contracts/bridge/interfaces/IL1InteropHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

import {AddressAlreadySet, SlotOccupied, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

/// @title L1InteropHandlerTest
/// @notice Unit tests for the handler-specific surface of `L1InteropHandler`: initialization, the one-time
/// dependency setters, the nullifier-gated transient settlement-layer recording, and the pause controls.
/// @dev The full `finalizeDeposit` proof/parse/dispatch flow is exercised end-to-end by the integration suite
/// (`AssetRouterTest`, the Bridgehub withdrawal harnesses); here we isolate the pieces the handler owns directly.
contract L1InteropHandlerTest is Test {
    L1InteropHandler internal handler;
    L1InteropHandler internal handlerImpl;

    address internal owner = makeAddr("owner");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal messageRoot = makeAddr("messageRoot");
    address internal assetRouter = makeAddr("assetRouter");
    address internal nullifier = makeAddr("nullifier");

    function setUp() public {
        handlerImpl = new L1InteropHandler(IMessageRootBase(messageRoot));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(handlerImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1InteropHandler.initialize.selector, owner)
        );
        handler = L1InteropHandler(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsOwnerAndMessageRoot() public view {
        assertEq(handler.owner(), owner, "owner mismatch");
        assertEq(address(handler.MESSAGE_ROOT()), messageRoot, "MESSAGE_ROOT mismatch");
    }

    function test_Initialize_RevertWhen_ZeroOwner() public {
        L1InteropHandler impl = new L1InteropHandler(IMessageRootBase(messageRoot));
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeWithSelector(L1InteropHandler.initialize.selector, address(0))
        );
    }

    function test_Initialize_RevertWhen_CalledTwice() public {
        // The `reentrancyGuardInitializer` modifier runs first and rejects the second init with `SlotOccupied`.
        vm.expectRevert(SlotOccupied.selector);
        handler.initialize(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_SetL1AssetRouter_Happy() public {
        vm.prank(owner);
        handler.setL1AssetRouter(assetRouter);
        assertEq(address(handler.l1AssetRouter()), assetRouter);
    }

    function test_SetL1AssetRouter_RevertWhen_NotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        handler.setL1AssetRouter(assetRouter);
    }

    function test_SetL1AssetRouter_RevertWhen_Zero() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        handler.setL1AssetRouter(address(0));
    }

    function test_SetL1AssetRouter_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        handler.setL1AssetRouter(assetRouter);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AddressAlreadySet.selector, assetRouter));
        handler.setL1AssetRouter(makeAddr("otherRouter"));
    }

    function test_SetL1Nullifier_Happy() public {
        vm.prank(owner);
        handler.setL1Nullifier(nullifier);
        assertEq(handler.l1Nullifier(), nullifier);
    }

    function test_SetL1Nullifier_RevertWhen_NotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        handler.setL1Nullifier(nullifier);
    }

    function test_SetL1Nullifier_RevertWhen_Zero() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        handler.setL1Nullifier(address(0));
    }

    function test_SetL1Nullifier_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        handler.setL1Nullifier(nullifier);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AddressAlreadySet.selector, nullifier));
        handler.setL1Nullifier(makeAddr("otherNullifier"));
    }

    /*//////////////////////////////////////////////////////////////
                    TRANSIENT SETTLEMENT LAYER
    //////////////////////////////////////////////////////////////*/

    function test_GetTransientSettlementLayer_InitiallyZero() public view {
        (uint256 settlementLayer, uint256 batchNumber) = handler.getTransientSettlementLayer();
        assertEq(settlementLayer, 0);
        assertEq(batchNumber, 0);
    }

    function test_SetTransientSettlementLayer_OnlyNullifier() public {
        vm.prank(owner);
        handler.setL1Nullifier(nullifier);

        vm.expectEmit(true, false, false, false, address(handler));
        emit IL1InteropHandler.TransientSettlementLayerSet(777);

        vm.prank(nullifier);
        handler.setTransientSettlementLayer(777, 42);

        // The transient value persists for the duration of this test transaction.
        (uint256 settlementLayer, uint256 batchNumber) = handler.getTransientSettlementLayer();
        assertEq(settlementLayer, 777, "settlement layer mismatch");
        assertEq(batchNumber, 42, "batch number mismatch");
    }

    function test_SetTransientSettlementLayer_RevertWhen_NotNullifier() public {
        vm.prank(owner);
        handler.setL1Nullifier(nullifier);

        address notNullifier = makeAddr("notNullifier");
        vm.prank(notNullifier);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNullifier));
        handler.setTransientSettlementLayer(1, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_Pause_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        handler.pause();
    }

    function test_PauseUnpause_Owner() public {
        vm.prank(owner);
        handler.pause();
        assertTrue(handler.paused());
        vm.prank(owner);
        handler.unpause();
        assertFalse(handler.paused());
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetL1AssetRouter(address _router) public {
        vm.assume(_router != address(0));
        vm.prank(owner);
        handler.setL1AssetRouter(_router);
        assertEq(address(handler.l1AssetRouter()), _router);
    }

    function testFuzz_SetL1Nullifier(address _nullifier) public {
        vm.assume(_nullifier != address(0));
        vm.prank(owner);
        handler.setL1Nullifier(_nullifier);
        assertEq(handler.l1Nullifier(), _nullifier);
    }
}
