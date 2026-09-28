// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
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

    function test_acceptsProtocolCeilingWithHigherStoredLimit() public pure {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        testTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT - 1;
        validateL1ToL2Transaction(testTx, type(uint256).max, type(uint256).max);
        testTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        validateL1ToL2Transaction(testTx, type(uint256).max, type(uint256).max);
    }

    function test_rejectsOneGasAboveProtocolCeiling() public {
        _assertExceedsProtocolCeiling(PRIORITY_TX_MAX_GAS_LIMIT + 1);
    }

    function testFuzz_rejectsAboveProtocolCeiling(uint256 _gasLimit) public {
        _assertExceedsProtocolCeiling(bound(_gasLimit, PRIORITY_TX_MAX_GAS_LIMIT + 1, type(uint256).max));
    }

    function _assertExceedsProtocolCeiling(uint256 _gasLimit) internal {
        L2CanonicalTransaction memory testTx = createTestTransaction();
        testTx.gasLimit = _gasLimit;
        vm.expectRevert(TooMuchGas.selector);
        validateL1ToL2Transaction(testTx, type(uint256).max, type(uint256).max);
    }
}
