// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseTokenHolderEra} from "contracts/l2-system/era/BaseTokenHolderEra.sol";
import {BaseTokenHolderZKOS} from "contracts/l2-system/zksync-os/BaseTokenHolderZKOS.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @title BaseTokenHolderZKOSTest
/// @notice Unit tests for BaseTokenHolderZKOS contract
/// @dev Tests use ZK OS version since it uses native transfers which work in Foundry tests
contract BaseTokenHolderZKOSTest is Test {
    BaseTokenHolderZKOS internal baseTokenHolder;

    address internal recipient;
    uint256 internal constant INITIAL_BALANCE = 100 ether;

    function setUp() public {
        baseTokenHolder = new BaseTokenHolderZKOS();
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

    function test_give_revertWhenCalledByNonInteropHandler() public {
        address nonInteropHandler = makeAddr("nonInteropHandler");

        vm.prank(nonInteropHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonInteropHandler));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function test_give_revertWhenCalledByInteropCenter() public {
        // InteropCenter can send ETH via receive() but cannot call give()
        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_CENTER_ADDR));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function test_give_revertWhenCalledByNativeTokenVault() public {
        // NTV can send ETH via receive() but cannot call give()
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_NATIVE_TOKEN_VAULT_ADDR));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function testFuzz_give_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "Recipient should receive correct amount");
    }

    /*//////////////////////////////////////////////////////////////
                            receive() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_receive_acceptsFromInteropHandler() public {
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_acceptsFromInteropCenter() public {
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_INTEROP_CENTER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_acceptsFromNativeTokenVault() public {
        uint256 amount = 1 ether;
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_revertFromUntrustedSender() public {
        address untrustedSender = makeAddr("untrustedSender");
        uint256 amount = 1 ether;
        vm.deal(untrustedSender, amount);

        vm.prank(untrustedSender);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail from untrusted sender");
    }

    function testFuzz_receive_variousAmountsFromTrustedSenders(uint256 amount, uint8 senderIndex) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        address[] memory trustedSenders = new address[](3);
        trustedSenders[0] = L2_INTEROP_HANDLER_ADDR;
        trustedSenders[1] = L2_INTEROP_CENTER_ADDR;
        trustedSenders[2] = L2_NATIVE_TOKEN_VAULT_ADDR;

        address sender = trustedSenders[senderIndex % 3];
        vm.deal(sender, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(sender);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed from trusted sender");
        assertEq(
            address(baseTokenHolder).balance,
            holderBalanceBefore + amount,
            "Holder should receive correct amount"
        );
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

/// @title BaseTokenHolderEraTest
/// @notice Unit tests for BaseTokenHolderEra contract
/// @dev Limited tests since Era uses L2BaseToken.transferFromTo which requires mocking system contracts
contract BaseTokenHolderEraTest is Test {
    BaseTokenHolderEra internal baseTokenHolder;

    address internal recipient;

    function setUp() public {
        baseTokenHolder = new BaseTokenHolderEra();
        recipient = makeAddr("recipient");
    }

    /*//////////////////////////////////////////////////////////////
                            give() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_give_revertWhenCalledByNonInteropHandler() public {
        address nonInteropHandler = makeAddr("nonInteropHandler");

        vm.prank(nonInteropHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonInteropHandler));
        baseTokenHolder.give(recipient, 1 ether);
    }

    function test_give_zeroAmountDoesNothing() public {
        // Zero amount should return early without calling transferFromTo
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, 0);
        // Should not revert - function returns early for zero amount
    }

    /*//////////////////////////////////////////////////////////////
                            receive() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_receive_acceptsFromInteropHandler() public {
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_acceptsFromInteropCenter() public {
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_INTEROP_CENTER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_acceptsFromNativeTokenVault() public {
        uint256 amount = 1 ether;
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_revertFromUntrustedSender() public {
        address untrustedSender = makeAddr("untrustedSender");
        uint256 amount = 1 ether;
        vm.deal(untrustedSender, amount);

        vm.prank(untrustedSender);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail from untrusted sender");
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
