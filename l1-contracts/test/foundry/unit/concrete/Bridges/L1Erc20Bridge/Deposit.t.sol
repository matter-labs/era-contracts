// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {EmptyDeposit, ValueMismatch, TokensWithFeesNotSupported} from "contracts/common/L1ContractErrors.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract DepositTest is L1Erc20BridgeTest {
    event DepositInitiated(
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address indexed to,
        address l1Token,
        uint256 amount
    );

    function test_RevertWhen_depositAmountIsZero() public {
        vm.expectRevert(EmptyDeposit.selector);
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(token),
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0,
            _amount: 0,
            _refundRecipient: address(0)
        });
    }

    function test_RevertWhen_legacyDepositAmountIsZero() public {
        vm.expectRevert(EmptyDeposit.selector);
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(token),
            _amount: 0,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_RevertWhen_depositTokenIsNotContract() public {
        vm.expectRevert();
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: makeAddr("EOA"),
            _amount: 1,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_RevertWhen_legacyDepositTokenIsNotContract() public {
        vm.expectRevert();
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: makeAddr("EOA"),
            _amount: 1,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_RevertWhen_depositTokenTransferFailed() public {
        vm.expectRevert("ERC20: insufficient allowance");
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(token),
            _amount: 1,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_RevertWhen_legacyDepositTokenTransferFailed() public {
        vm.expectRevert("ERC20: insufficient allowance");
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(token),
            _amount: 1,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_RevertWhen_depositTransferAmountIsDifferent() public {
        uint256 amount = 2;
        vm.prank(alice);
        feeOnTransferToken.approve(address(bridge), amount);
        vm.expectRevert(TokensWithFeesNotSupported.selector);
        vm.prank(alice);
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(feeOnTransferToken),
            _amount: amount,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_RevertWhen_legacyDepositTransferAmountIsDifferent() public {
        uint256 amount = 4;
        vm.prank(alice);
        feeOnTransferToken.approve(address(bridge), amount);
        vm.expectRevert(TokensWithFeesNotSupported.selector);
        vm.prank(alice);
        bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(feeOnTransferToken),
            _amount: amount,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
    }

    function test_depositSuccessfully() public {
        uint256 amount = 8;
        bytes32 l2TxHash = keccak256("txHash");

        vm.mockCall(
            sharedBridgeAddress,
            abi.encodeWithSelector(
                IL1SharedBridge.depositLegacyErc20Bridge.selector,
                alice,
                randomSigner,
                address(token),
                amount,
                0,
                0,
                address(0)
            ),
            abi.encode(l2TxHash)
        );

        vm.prank(alice);
        token.approve(address(bridge), amount);
        vm.prank(alice);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(bridge));
        // solhint-disable-next-line func-named-parameters
        emit DepositInitiated(l2TxHash, alice, randomSigner, address(token), amount);
        bytes32 txHash = bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0,
            _refundRecipient: address(0)
        });
        assertEq(txHash, l2TxHash);

        uint256 depositedAmount = bridge.depositAmount(alice, address(token), l2TxHash);
        assertEq(amount, depositedAmount);
    }

    function test_legacyDepositSuccessfully() public {
        uint256 amount = 8;
        bytes32 l2TxHash = keccak256("txHash");

        uint256 depositedAmountBefore = bridge.depositAmount(alice, address(token), l2TxHash);
        assertEq(depositedAmountBefore, 0);

        vm.mockCall(
            sharedBridgeAddress,
            abi.encodeWithSelector(
                IL1SharedBridge.depositLegacyErc20Bridge.selector,
                alice,
                randomSigner,
                address(token),
                amount,
                0,
                0,
                address(0)
            ),
            abi.encode(l2TxHash)
        );

        vm.prank(alice);
        token.approve(address(bridge), amount);
        vm.prank(alice);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(bridge));
        // solhint-disable-next-line func-named-parameters
        emit DepositInitiated(l2TxHash, alice, randomSigner, address(token), amount);
        bytes32 txHash = bridge.deposit({
            _l2Receiver: randomSigner,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: 0,
            _l2TxGasPerPubdataByte: 0
        });
        assertEq(txHash, l2TxHash);

        uint256 depositedAmount = bridge.depositAmount(alice, address(token), l2TxHash);
        assertEq(amount, depositedAmount);
    }
}
