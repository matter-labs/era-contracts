// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgeMintNotImplemented, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

abstract contract L2WethTestAbstract is Test, SharedL2ContractDeployer {
    function test_shouldDepositWethByCallingDeposit() public {
        uint256 amount = 100;
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(address(this)), amount);
    }

    function test_shouldDepositWethBySendingEth() public {
        uint256 amount = 100;
        address(weth).call{value: amount}("");
        assertEq(weth.balanceOf(address(this)), amount);
    }

    function test_revertWhenDepositingWithRandomCalldata() public {
        (bool success, ) = address(weth).call{value: 100}(hex"00000000");
        assertEq(success, false);
    }

    function test_shouldWithdrawWethToL2Eth() public {
        address sender = makeAddr("sender");
        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.deposit{value: amount}();

        vm.prank(sender);
        weth.withdraw(amount);

        assertEq(weth.balanceOf(sender), 0);
        assertEq(address(sender).balance, amount);
    }

    function test_shouldDepositWethToAnotherAccount() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");

        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.depositTo{value: amount}(receiver);

        assertEq(weth.balanceOf(receiver), amount);
        assertEq(weth.balanceOf(sender), 0);
    }

    function test_shouldWithdrawWethToAnotherAccount() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");

        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.deposit{value: amount}();

        vm.prank(sender);
        weth.withdrawTo(receiver, amount);

        assertEq(receiver.balance, amount);
        assertEq(sender.balance, 0);
    }

    function test_revertWhenWithdrawingMoreThanBalance() public {
        vm.expectRevert("ERC20: burn amount exceeds balance");
        weth.withdraw(1);
    }

    function test_revertWhenCallingBridgeMint() public {
        vm.expectRevert(abi.encodeWithSelector(BridgeMintNotImplemented.selector));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        weth.bridgeMint(address(1), 1);
    }

    function test_revertWhenCallingBridgeMintDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        weth.bridgeMint(address(1), 1);
    }

    function test_revertWhenCallingBridgeBurnDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        weth.bridgeBurn(address(1), 1);
    }
}

/* Coverage improvement suggestions
  Happy-path

  1. test_emitsDepositEvent — assert Deposit(address indexed dst, uint256 wad) (and Transfer(address(0), dst, wad) if the WETH inherits ERC20 mint
  events) via vm.expectEmit on weth.deposit{value: amount}(). Today none of the deposit tests verify event emissions; only post-state balances. Same
   gap on the withdraw side (Withdrawal event).
  2. test_totalSupplyTracksDepositsAndWithdrawals — sequence: snapshot totalSupply() → deposit → assert +amount → withdraw → assert returns to
  baseline. Catches "balance updated, totalSupply not" regressions which are a classic WETH foot-gun.
  3. test_sequentialDepositsAccumulate — call deposit{value: a}() then deposit{value: b}() from the same sender; assert balanceOf(sender) == a + b.
  Pins the additive update path against silent overwrites.

  Unhappy-path

  4. test_revertWhenDepositingToZeroAddress — call weth.depositTo{value: amount}(address(0)). Standard OZ ERC20 reverts on mint to zero; lock the
  behavior here.
  5. test_revertWhenWithdrawingToZeroAddress — call weth.withdrawTo(address(0), amount). Either reverts on the ETH transfer or silently burns;
  whichever the design chose, pin it.
  6. test_revertWhenCallingBridgeBurnFromAuthorizedRouter — symmetric to test_revertWhenCallingBridgeMint (L91-95) but for bridgeBurn. Currently
  only the unauthorized-caller revert (test_revertWhenCallingBridgeBurnDirectly) is tested. If bridgeBurn from L2_ASSET_ROUTER_ADDR reverts with
  BridgeMintNotImplemented-equivalent, lock it; if it succeeds, that's a different finding worth surfacing.
  7. test_revertWhenDepositingZeroValue — call weth.deposit{value: 0}(). Decide intent: silent no-op (typical WETH9) or revert. Today neither is
  locked.

  Edge cases

  8. test_withdrawZero — call weth.withdraw(0). Pin whether it's a no-op or emits a zero-value Withdrawal event.
  9. test_depositOneWei — boundary at value = 1; assert balanceOf == 1 and totalSupply == 1.
  10. test_withdrawAllAfterMultipleDeposits — deposit twice, withdraw the sum, assert balance and totalSupply are zero. Cross-checks accumulation
  against drain.

  Adversarial

  11. test_withdrawTo_reentrancyOnRecipient — deploy a recipient contract whose receive() payable calls back into weth.withdraw(...) for the same
  sender. Verify the second call either reverts (already-zero balance) or completes safely. Classic WETH reentrancy seam — pinning it documents the
  intended behavior.
  12. test_depositTo_recipientCannotFrontrunBalance — sender calls weth.depositTo{value: a}(receiver); before the call settles in the test scope,
  snapshot weth.balanceOf(receiver) from a different observer to confirm there's no transient state observable. Pure paranoia / invariant lock;
  lowest priority.

*/
