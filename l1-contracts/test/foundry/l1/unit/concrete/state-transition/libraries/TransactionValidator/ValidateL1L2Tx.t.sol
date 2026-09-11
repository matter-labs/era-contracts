// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {PubdataGreaterThanLimit, TooMuchGas, ValidateTxnNotEnoughGas} from "contracts/common/L1ContractErrors.sol";

contract ValidateL1L2TxTest is TransactionValidatorSharedTest {
    function test_BasicRequestL1L2() public pure {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        testTx.maxFeePerGas = 100000;
        testTx.gasLimit = 500000;
        validateL1ToL2Transaction(testTx, 500000, 100000);
    }

    function test_RevertWhen_GasLimitHigherThanMax() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        // We should fail, if user asks for too much gas.
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = priorityTxMaxGasLimit + 1000000;
        vm.expectRevert(TooMuchGas.selector);
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit, 100000);
    }

    function test_RevertWhen_TooMuchPubdata() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        // We should fail, if user's transaction could output too much pubdata.
        // We can allow only 100k of pubdata (otherwise we'd exceed the ethereum calldata limits).

        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = priorityTxMaxGasLimit;
        // With no batch overhead on ZKsync OS, a pubdata price of 1 makes the whole
        // gas limit (500k) count as potential pubdata.
        testTx.gasPerPubdataByteLimit = 1;
        vm.expectRevert(abi.encodeWithSelector(PubdataGreaterThanLimit.selector, 100000, 500000));
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit, 100000);
    }

    function test_RevertWhen_BelowMinimumCost() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = 20000;
        vm.expectRevert(ValidateTxnNotEnoughGas.selector);
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit, 100000);
    }

    function test_RevertWhen_HugePubdata() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = 400000;
        // Setting huge pubdata limit should cause the panic.
        testTx.gasPerPubdataByteLimit = type(uint256).max;
        vm.expectRevert();
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit, 100000);
    }

    function test_ShouldAllowLargeTransactions() public pure {
        // If the governance is fine with, the user can send a transaction with a huge gas limit.
        L2CanonicalTransaction memory testTx = createTestTransaction();

        uint256 largeGasLimit = 2_000_000_000;

        testTx.gasPerPubdataByteLimit = 1;
        testTx.gasLimit = largeGasLimit;

        // This transaction could publish 2B bytes of pubdata & has 2B gas, which is more than would be typically
        // allowed in the production system
        validateL1ToL2Transaction(testTx, largeGasLimit, largeGasLimit);
    }
}
