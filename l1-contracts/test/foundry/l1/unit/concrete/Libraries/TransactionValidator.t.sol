// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {InvalidUpgradeTxn, PubdataGreaterThanLimit, TooMuchGas, TxnBodyGasLimitNotEnoughGas, UpgradeTxVerifyParam, ValidateTxnNotEnoughGas} from "contracts/common/L1ContractErrors.sol";
import {TX_SLOT_OVERHEAD_L2_GAS, MEMORY_OVERHEAD_GAS} from "contracts/common/Config.sol";

/// @notice Unit tests for TransactionValidator library
contract TransactionValidatorTest is Test {
    // ============ getOverheadForTransaction Tests ============

    function test_getOverheadForTransaction_basicValues() public pure {
        uint256 overhead = TransactionValidator.getOverheadForTransaction(100);

        // Should be at least TX_SLOT_OVERHEAD_L2_GAS
        assertTrue(overhead >= TX_SLOT_OVERHEAD_L2_GAS);
    }

    function test_getOverheadForTransaction_zeroLength() public pure {
        uint256 overhead = TransactionValidator.getOverheadForTransaction(0);

        // With zero length, overhead should be TX_SLOT_OVERHEAD_L2_GAS
        assertEq(overhead, TX_SLOT_OVERHEAD_L2_GAS);
    }

    function test_getOverheadForTransaction_largeEncoding() public pure {
        // Large encoding should result in memory overhead being dominant
        uint256 largeLength = 10000;
        uint256 overhead = TransactionValidator.getOverheadForTransaction(largeLength);

        uint256 expectedMemoryOverhead = MEMORY_OVERHEAD_GAS * largeLength;

        // Should be the max of slot overhead and memory overhead
        if (expectedMemoryOverhead > TX_SLOT_OVERHEAD_L2_GAS) {
            assertEq(overhead, expectedMemoryOverhead);
        } else {
            assertEq(overhead, TX_SLOT_OVERHEAD_L2_GAS);
        }
    }

    function testFuzz_getOverheadForTransaction(uint256 encodingLength) public pure {
        vm.assume(encodingLength < type(uint128).max);

        uint256 overhead = TransactionValidator.getOverheadForTransaction(encodingLength);

        // Should always be at least TX_SLOT_OVERHEAD_L2_GAS
        assertTrue(overhead >= TX_SLOT_OVERHEAD_L2_GAS);

        uint256 memoryOverhead = MEMORY_OVERHEAD_GAS * encodingLength;
        if (memoryOverhead > TX_SLOT_OVERHEAD_L2_GAS) {
            assertEq(overhead, memoryOverhead);
        }
    }

    // ============ getTransactionBodyGasLimit Tests ============

    function test_getTransactionBodyGasLimit_basicValues() public pure {
        uint256 totalGas = 1_000_000;
        uint256 encodingLength = 100;

        uint256 bodyGas = TransactionValidator.getTransactionBodyGasLimit(totalGas, encodingLength, false);

        uint256 expectedOverhead = TransactionValidator.getOverheadForTransaction(encodingLength);
        assertEq(bodyGas, totalGas - expectedOverhead);
    }

    function test_getTransactionBodyGasLimit_zkSyncOS() public pure {
        uint256 totalGas = 1_000_000;
        uint256 encodingLength = 100;

        // With zkSyncOS, there's no overhead
        uint256 bodyGas = TransactionValidator.getTransactionBodyGasLimit(totalGas, encodingLength, true);

        assertEq(bodyGas, totalGas);
    }

    function test_getTransactionBodyGasLimit_revertsIfNotEnoughGas() public {
        uint256 encodingLength = 100;
        uint256 overhead = TransactionValidator.getOverheadForTransaction(encodingLength);

        // Gas limit less than overhead
        uint256 insufficientGas = overhead - 1;

        vm.expectRevert(TxnBodyGasLimitNotEnoughGas.selector);
        TransactionValidator.getTransactionBodyGasLimit(insufficientGas, encodingLength, false);
    }

    function test_getTransactionBodyGasLimit_exactOverhead() public pure {
        uint256 encodingLength = 100;
        uint256 overhead = TransactionValidator.getOverheadForTransaction(encodingLength);

        // Gas limit exactly at overhead should result in 0 body gas
        uint256 bodyGas = TransactionValidator.getTransactionBodyGasLimit(overhead, encodingLength, false);

        assertEq(bodyGas, 0);
    }

    // ============ getMinimalPriorityTransactionGasLimit Tests ============

    function test_getMinimalPriorityTransactionGasLimit_basicValues() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            1000, // encoding length
            500, // calldata length
            2, // factory deps
            800, // gas per pubdata
            1 gwei, // max fee per gas
            false // not zkSyncOS
        );

        assertTrue(minGas > 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_zkSyncOS() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            1000, // encoding length
            500, // calldata length
            2, // factory deps
            800, // gas per pubdata
            1 gwei, // max fee per gas
            true // zkSyncOS
        );

        assertTrue(minGas > 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_zkSyncOS_freeTransaction() public pure {
        // Free transaction (max fee = 0) in zkSyncOS mode
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            1000, // encoding length
            500, // calldata length
            0, // factory deps
            800, // gas per pubdata
            0, // max fee per gas = 0 for free/special txs
            true // zkSyncOS
        );

        assertTrue(minGas > 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_withFactoryDeps() public pure {
        uint256 minGasWithoutDeps = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            1000,
            500,
            0, // no factory deps
            800,
            1 gwei,
            false
        );

        uint256 minGasWithDeps = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            1000,
            500,
            5, // 5 factory deps
            800,
            1 gwei,
            false
        );

        // More factory deps should require more gas
        assertTrue(minGasWithDeps > minGasWithoutDeps);
    }

    function test_getMinimalPriorityTransactionGasLimit_longerEncoding() public pure {
        uint256 minGasShort = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            100, // short encoding
            50,
            0,
            800,
            1 gwei,
            false
        );

        uint256 minGasLong = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            10000, // long encoding
            5000,
            0,
            800,
            1 gwei,
            false
        );

        // Longer encoding should require more gas
        assertTrue(minGasLong > minGasShort);
    }

    // ============ validateUpgradeTransaction Tests ============

    function test_validateUpgradeTransaction_validTransaction() public pure {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();

        // Should not revert
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfFromTooLarge() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.from = uint256(type(uint16).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.From));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfToTooLarge() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.to = uint256(type(uint160).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.To));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfPaymasterNotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.paymaster = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Paymaster));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfValueNotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.value = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Value));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfMaxFeeNotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.maxFeePerGas = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxFeePerGas));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfMaxPriorityFeeNotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.maxPriorityFeePerGas = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxPriorityFeePerGas));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfReserved0NotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved0));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfReserved1TooLarge() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[1] = uint256(type(uint160).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved1));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfReserved2NotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[2] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved2));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfReserved3NotZero() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[3] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved3));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfSignatureNotEmpty() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.signature = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Signature));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfPaymasterInputNotEmpty() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.paymasterInput = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.PaymasterInput));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsIfReservedDynamicNotEmpty() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reservedDynamic = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.ReservedDynamic));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    // ============ validateL1ToL2Transaction Tests ============

    function test_validateL1ToL2Transaction_revertsIfTooMuchGas() public {
        L2CanonicalTransaction memory tx = _createBasicL2Transaction();
        tx.gasLimit = 100_000_000_000; // Very high gas limit

        bytes memory encoded = abi.encode(tx);

        vm.expectRevert(TooMuchGas.selector);
        TransactionValidator.validateL1ToL2Transaction(
            tx,
            encoded,
            1_000_000, // priority tx max gas limit (much lower)
            1_000_000, // priority tx max pubdata
            false
        );
    }

    function test_validateL1ToL2Transaction_revertsIfPubdataTooHigh() public {
        L2CanonicalTransaction memory tx = _createBasicL2Transaction();
        tx.gasLimit = 10_000_000;
        tx.gasPerPubdataByteLimit = 1; // Very low pubdata price = high pubdata amount

        bytes memory encoded = abi.encode(tx);
        uint256 overhead = TransactionValidator.getOverheadForTransaction(encoded.length);
        uint256 bodyGas = tx.gasLimit - overhead;
        uint256 expectedPubdata = bodyGas / tx.gasPerPubdataByteLimit;

        vm.expectRevert(abi.encodeWithSelector(PubdataGreaterThanLimit.selector, 1000, expectedPubdata));
        TransactionValidator.validateL1ToL2Transaction(tx, encoded, 100_000_000, 1000, false);
    }

    // ============ Helper Functions ============

    function _createValidUpgradeTransaction() internal pure returns (L2CanonicalTransaction memory) {
        uint256[] memory factoryDeps = new uint256[](0);
        uint256[4] memory reserved;
        reserved[0] = 0;
        reserved[1] = 0;
        reserved[2] = 0;
        reserved[3] = 0;

        return
            L2CanonicalTransaction({
                txType: 254, // Protocol upgrade type
                from: 0x8001, // Within system contract range
                to: uint160(0xABCD), // Valid address
                gasLimit: 1_000_000,
                gasPerPubdataByteLimit: 800,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                paymaster: 0,
                nonce: 0,
                value: 0,
                reserved: reserved,
                data: hex"",
                signature: hex"",
                factoryDeps: factoryDeps,
                paymasterInput: hex"",
                reservedDynamic: hex""
            });
    }

    function _createBasicL2Transaction() internal pure returns (L2CanonicalTransaction memory) {
        uint256[] memory factoryDeps = new uint256[](0);
        uint256[4] memory reserved;

        return
            L2CanonicalTransaction({
                txType: 255,
                from: uint256(uint160(address(0x1234))),
                to: uint256(uint160(address(0x5678))),
                gasLimit: 1_000_000,
                gasPerPubdataByteLimit: 800,
                maxFeePerGas: 1 gwei,
                maxPriorityFeePerGas: 0,
                paymaster: 0,
                nonce: 0,
                value: 0,
                reserved: reserved,
                data: hex"",
                signature: hex"",
                factoryDeps: factoryDeps,
                paymasterInput: hex"",
                reservedDynamic: hex""
            });
    }
}
