// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";

contract ValidateL1L2TxTest is TransactionValidatorSharedTest {
    function test_BasicRequestL1L2() public pure {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        testTx.gasLimit = 500000;
        validateL1ToL2Transaction(testTx, 500000, 100000);
    }

    function test_RevertWhen_GasLimitDoesntCoverOverhead() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        // The limit is so low, that it doesn't even cover the overhead
        testTx.gasLimit = 0;
        vm.expectRevert(bytes("my"));
        validateL1ToL2Transaction(testTx, 500000, 100000);
    }

    function test_RevertWhen_GasLimitHigherThanMax() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        // We should fail, if user asks for too much gas.
        // Notice, that we subtract the transaction overhead costs from the user's gas limit
        // before checking that it is below the max gas limit.
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = priorityTxMaxGasLimit + 1000000;
        vm.expectRevert(bytes("ui"));
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit, 100000);
    }

    function test_RevertWhen_TooMuchPubdata() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        // We should fail, if user's transaction could output too much pubdata.
        // We can allow only 99k of pubdata (otherwise we'd exceed the ethereum calldata limits).

        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = priorityTxMaxGasLimit;
        // So if the pubdata costs per byte is 1 - then this transaction could produce 500k of pubdata.
        // (hypothetically, assuming all the gas was spent on writing).
        testTx.gasPerPubdataByteLimit = 1;
        vm.expectRevert(bytes("uk"));
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit, 100000);
    }

    function test_RevertWhen_BelowMinimumCost() public {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = 200000;
        vm.expectRevert(bytes("up"));
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

    function test_ShouldReturnCorrectOverhead_ShortTx() public pure {
        require(
            getOverheadForTransaction(32) == 10_000,
            "The overhead for short transaction must be equal to the tx slot overhead"
        );
    }

    function test_ShouldReturnCorrectOverhead_LongTx() public pure {
        require(
            getOverheadForTransaction(1000000) == 1000000 * 10,
            "The overhead for long transaction must be equal to the tx slot overhead"
        );
    }
}
