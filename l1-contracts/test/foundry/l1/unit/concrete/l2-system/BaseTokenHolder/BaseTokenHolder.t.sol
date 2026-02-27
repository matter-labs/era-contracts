// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {L2_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @title BaseTokenHolderTest
/// @notice Unit tests for BaseTokenHolder contract
contract BaseTokenHolderTest is Test {
    BaseTokenHolder internal baseTokenHolder;

    address internal recipient;
    uint256 internal constant INITIAL_BALANCE = 100 ether;

    function setUp() public {
        baseTokenHolder = new BaseTokenHolder();
        recipient = makeAddr("recipient");

        // Fund the BaseTokenHolder contract
        vm.deal(address(baseTokenHolder), INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            give() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_give_successFromInteropHandler() public {
        uint256 amount = 1 ether;
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleFinalizeBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "Recipient should receive tokens");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore - amount, "Holder balance should decrease");
    }

    function test_give_zeroAmountDoesNothing() public {
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, 0);

        assertEq(recipient.balance, recipientBalanceBefore, "Recipient balance should not change");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore, "Holder balance should not change");
    }

    function test_give_notifiesAssetTracker() public {
        uint256 amount = 1 ether;

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleFinalizeBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleFinalizeBaseTokenBridgingOnL2.selector, amount)
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount);
    }

    function test_give_revertWhenCalledByNonInteropHandler() public {
        address nonInteropHandler = makeAddr("nonInteropHandler");

        vm.prank(nonInteropHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonInteropHandler));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function test_give_revertWhenCalledByInteropCenter() public {
        // InteropCenter can call burnAndStartBridging() but cannot call give()
        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_CENTER_ADDR));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function test_give_revertWhenCalledByNativeTokenVault() public {
        // NTV can call burnAndStartBridging() but cannot call give()
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_NATIVE_TOKEN_VAULT_ADDR));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function testFuzz_give_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleFinalizeBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "Recipient should receive correct amount");
    }

    /*//////////////////////////////////////////////////////////////
                            receive() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_receive_acceptsFromL2BaseToken() public {
        uint256 amount = 1 ether;
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_rejectFromInteropHandler() public {
        // InteropHandler should use give() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - InteropHandler should use give()");
    }

    function test_receive_rejectFromInteropCenter() public {
        // InteropCenter should use burnAndStartBridging() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - InteropCenter should use burnAndStartBridging()");
    }

    function test_receive_rejectFromNativeTokenVault() public {
        // NTV should use burnAndStartBridging() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - NTV should use burnAndStartBridging()");
    }

    function test_receive_revertFromUntrustedSender() public {
        address untrustedSender = makeAddr("untrustedSender");
        uint256 amount = 1 ether;
        vm.deal(untrustedSender, amount);

        vm.prank(untrustedSender);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail from untrusted sender");
    }

    function testFuzz_receive_variousAmountsFromL2BaseToken(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed from L2BaseToken");
        assertEq(
            address(baseTokenHolder).balance,
            holderBalanceBefore + amount,
            "Holder should receive correct amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    burnAndStartBridging() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_burnAndStartBridging_successFromInteropHandler() public {
        uint256 amount = 1 ether;
        uint256 toChainId = 271;

        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        // Mock asset tracker to accept the call
        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector, toChainId, amount)
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(toChainId);
    }

    function test_burnAndStartBridging_successFromInteropCenter() public {
        uint256 amount = 1 ether;
        uint256 toChainId = 271;

        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(toChainId);
    }

    function test_burnAndStartBridging_successFromNativeTokenVault() public {
        uint256 amount = 1 ether;
        uint256 toChainId = 271;

        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(toChainId);
    }

    function test_burnAndStartBridging_successFromL2BaseToken() public {
        uint256 amount = 1 ether;
        uint256 toChainId = 271;

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, amount);

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(toChainId);
    }

    function test_burnAndStartBridging_revertFromUnauthorizedCaller() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        uint256 amount = 1 ether;
        uint256 toChainId = 271;

        vm.deal(unauthorizedCaller, amount);

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, unauthorizedCaller));
        baseTokenHolder.burnAndStartBridging{value: amount}(toChainId);
    }

    function test_burnAndStartBridging_callsAssetTrackerWithCorrectParams() public {
        uint256 amount = 2 ether;
        uint256 toChainId = 505;

        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector),
            abi.encode()
        );

        // Verify exact parameters passed to asset tracker
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector, toChainId, amount)
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(toChainId);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIBaseTokenHolder() public view {
        // Verify the contract implements the interface
        IBaseTokenHolder holder = IBaseTokenHolder(address(baseTokenHolder));
        // This should compile and not revert - interface is implemented
        assert(address(holder) == address(baseTokenHolder));
    }
}
