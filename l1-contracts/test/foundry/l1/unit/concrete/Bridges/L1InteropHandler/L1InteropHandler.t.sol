// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

import {SlotOccupied} from "contracts/common/L1ContractErrors.sol";

/// @title L1InteropHandlerTest
/// @notice Unit tests for the L1-specific surface of `L1InteropHandler`: proxy initialization. The full
/// `executeBundle` proof/parse/dispatch flow is exercised end-to-end by the integration suite (`AssetRouterTest`,
/// the Bridgehub withdrawal harnesses).
contract L1InteropHandlerTest is Test {
    L1InteropHandler internal handler;
    L1InteropHandler internal handlerImpl;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal messageRoot = makeAddr("messageRoot");

    uint256 internal constant L1_CHAIN_ID = 1;

    function setUp() public {
        handlerImpl = new L1InteropHandler(IMessageRootBase(messageRoot));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(handlerImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1InteropHandler.initialize.selector, L1_CHAIN_ID)
        );
        handler = L1InteropHandler(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsState() public view {
        assertEq(handler.L1_CHAIN_ID(), L1_CHAIN_ID, "L1_CHAIN_ID mismatch");
        assertEq(address(handler.MESSAGE_ROOT()), messageRoot, "MESSAGE_ROOT mismatch");
    }

    function test_Initialize_RevertWhen_CalledTwice() public {
        // The `reentrancyGuardInitializer` modifier rejects the second init with `SlotOccupied`.
        vm.expectRevert(SlotOccupied.selector);
        handler.initialize(L1_CHAIN_ID);
    }
}
