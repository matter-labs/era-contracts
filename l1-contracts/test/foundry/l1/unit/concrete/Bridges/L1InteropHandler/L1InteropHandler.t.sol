// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {IL1InteropHandler} from "contracts/interop/interop-handler/IL1InteropHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

import {SlotOccupied, Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @title L1InteropHandlerTest
/// @notice Unit tests for the L1-specific surface of `L1InteropHandler`: initialization and the nullifier-gated
/// transient settlement-layer recording. The full `executeBundle` proof/parse/dispatch flow is exercised end-to-end
/// by the integration suite (`AssetRouterTest`, the Bridgehub withdrawal harnesses).
contract L1InteropHandlerTest is Test {
    L1InteropHandler internal handler;
    L1InteropHandler internal handlerImpl;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal messageRoot = makeAddr("messageRoot");
    address internal nullifier = makeAddr("nullifier");

    uint256 internal constant L1_CHAIN_ID = 1;

    function setUp() public {
        handlerImpl = new L1InteropHandler(IMessageRootBase(messageRoot));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(handlerImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1InteropHandler.initialize.selector, L1_CHAIN_ID, nullifier)
        );
        handler = L1InteropHandler(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsState() public view {
        assertEq(handler.L1_CHAIN_ID(), L1_CHAIN_ID, "L1_CHAIN_ID mismatch");
        assertEq(handler.l1Nullifier(), nullifier, "l1Nullifier mismatch");
        assertEq(address(handler.MESSAGE_ROOT()), messageRoot, "MESSAGE_ROOT mismatch");
    }

    function test_Initialize_RevertWhen_ZeroNullifier() public {
        L1InteropHandler impl = new L1InteropHandler(IMessageRootBase(messageRoot));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(0)));
        new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeWithSelector(L1InteropHandler.initialize.selector, L1_CHAIN_ID, address(0))
        );
    }

    function test_Initialize_RevertWhen_CalledTwice() public {
        // The `reentrancyGuardInitializer` modifier rejects the second init with `SlotOccupied`.
        vm.expectRevert(SlotOccupied.selector);
        handler.initialize(L1_CHAIN_ID, nullifier);
    }

    function test_InitL2_Reverts() public {
        // initL2 is the L2 system-contract entry point and is not usable on L1.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        handler.initL2(L1_CHAIN_ID);
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
        address notNullifier = makeAddr("notNullifier");
        vm.prank(notNullifier);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNullifier));
        handler.setTransientSettlementLayer(1, 1);
    }
}
