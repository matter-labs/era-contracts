pragma solidity 0.8.20;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";
import {IMailbox} from "solpp/zksync/interfaces/IMailbox.sol";
import {TransactionValidator} from "solpp/zksync/libraries/TransactionValidator.sol";

contract ValidateL1L2TxTest is TransactionValidatorSharedTest {
    function test_BasicRequestL1L2() public pure {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        testTx.gasLimit = 500000;
        validateL1ToL2Transaction(testTx, 500000);
    }

    function test_RevertWhen_GasLimitDoesntCoverOverhead() public {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        // The limit is so low, that it doesn't even cover the overhead
        testTx.gasLimit = 0;
        vm.expectRevert(bytes("my"));
        validateL1ToL2Transaction(testTx, 500000);
    }

    function test_RevertWhen_GasLimitHigherThanMax() public {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        // We should fail, if user asks for too much gas.
        // Notice, that we subtract the transaction overhead costs from the user's gas limit
        // before checking that it is below the max gas limit.
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = priorityTxMaxGasLimit + 1000000;
        vm.expectRevert(bytes("ui"));
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit);
    }

    function test_RevertWhen_TooMuchPubdata() public {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        // We should fail, if user's transaction could output too much pubdata.
        // We can allow only 99k of pubdata (otherwise we'd exceed the ethereum calldata limits).

        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = priorityTxMaxGasLimit;
        // So if the pubdata costs per byte is 1 - then this transaction could produce 500k of pubdata.
        // (hypothetically, assuming all the gas was spent on writing).
        testTx.gasPerPubdataByteLimit = 1;
        vm.expectRevert(bytes("uk"));
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit);
    }

    function test_RevertWhen_BelowMinimumCost() public {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = 200000;
        vm.expectRevert(bytes("up"));
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit);
    }

    function test_RevertWhen_HugePubdata() public {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        uint256 priorityTxMaxGasLimit = 500000;
        testTx.gasLimit = 400000;
        // Setting huge pubdata limit should cause the panic.
        testTx.gasPerPubdataByteLimit = type(uint256).max;
        vm.expectRevert();
        validateL1ToL2Transaction(testTx, priorityTxMaxGasLimit);
    }
}
