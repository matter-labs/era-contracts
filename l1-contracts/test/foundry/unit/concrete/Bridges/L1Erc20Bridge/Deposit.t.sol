// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";

contract DepositTest is L1Erc20BridgeTest {
    event DepositInitiated(
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address indexed to,
        address l1Token,
        uint256 amount
    );

    function test_RevertWhen_depositAmountIsZero() public {
        vm.expectRevert(bytes("0T"));
        bridge.deposit(randomSigner, address(token), 0, 0, 0, address(0));
    }

    function test_RevertWhen_legacyDepositAmountIsZero() public {
        vm.expectRevert(bytes("0T"));
        bridge.deposit(randomSigner, address(token), 0, 0, 0);
    }

    function test_RevertWhen_depositTokenIsNotContract() public {
        vm.expectRevert();
        bridge.deposit(randomSigner, makeAddr("EOA"), 1, 0, 0);
    }

    function test_RevertWhen_legacyDepositTokenIsNotContract() public {
        vm.expectRevert();
        bridge.deposit(randomSigner, makeAddr("EOA"), 1, 0, 0);
    }

    function test_RevertWhen_depositTokenTransferFailed() public {
        vm.expectRevert("ERC20: insufficient allowance");
        bridge.deposit(randomSigner, address(token), 1, 0, 0);
    }

    function test_RevertWhen_legacyDepositTokenTransferFailed() public {
        vm.expectRevert("ERC20: insufficient allowance");
        bridge.deposit(randomSigner, address(token), 1, 0, 0);
    }

    function test_RevertWhen_depositTransferAmountIsDifferent() public {
        uint256 amount = 2;
        vm.prank(alice);
        feeOnTransferToken.approve(address(bridge), amount);
        vm.expectRevert(bytes("3T"));
        vm.prank(alice);
        bridge.deposit(randomSigner, address(feeOnTransferToken), amount, 0, 0);
    }

    function test_RevertWhen_legacyDepositTransferAmountIsDifferent() public {
        uint256 amount = 4;
        vm.prank(alice);
        feeOnTransferToken.approve(address(bridge), amount);
        vm.expectRevert(bytes("3T"));
        vm.prank(alice);
        bridge.deposit(randomSigner, address(feeOnTransferToken), amount, 0, 0);
    }

    function test_depositSuccessfully() public {
        uint256 amount = 8;
        vm.prank(alice);
        token.approve(address(bridge), amount);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositInitiated(dummyL2DepositTxHash, alice, randomSigner, address(token), amount);
        bytes32 txHash = bridge.deposit(randomSigner, address(token), amount, 0, 0, address(0));
        assertEq(txHash, dummyL2DepositTxHash);

        uint256 depositedAmount = bridge.depositAmount(alice, address(token), dummyL2DepositTxHash);
        assertEq(amount, depositedAmount);
    }

    function test_legacyDepositSuccessfully() public {
        uint256 depositedAmountBefore = bridge.depositAmount(alice, address(token), dummyL2DepositTxHash);
        assertEq(depositedAmountBefore, 0);

        uint256 amount = 8;
        vm.prank(alice);
        token.approve(address(bridge), amount);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositInitiated(dummyL2DepositTxHash, alice, randomSigner, address(token), amount);
        bytes32 txHash = bridge.deposit(randomSigner, address(token), amount, 0, 0);
        assertEq(txHash, dummyL2DepositTxHash);

        uint256 depositedAmount = bridge.depositAmount(alice, address(token), dummyL2DepositTxHash);
        assertEq(amount, depositedAmount);
    }
}
