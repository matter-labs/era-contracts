// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    InvalidUpgradeTxn,
    PubdataGreaterThanLimit,
    TooMuchGas,
    TxnBodyGasLimitNotEnoughGas,
    UpgradeTxVerifyParam,
    ValidateTxnNotEnoughGas
} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for TransactionValidator library
contract TransactionValidatorTest is Test {
    // ============ getOverheadForTransaction Tests ============

    function test_getOverheadForTransaction_smallEncoding() public pure {
        uint256 overhead = TransactionValidator.getOverheadForTransaction(100);
        // Should be at least TX_SLOT_OVERHEAD_L2_GAS
        assertGt(overhead, 0);
    }

    function test_getOverheadForTransaction_largeEncoding() public pure {
        uint256 overhead = TransactionValidator.getOverheadForTransaction(10000);
        // Larger encoding should have larger overhead
        assertGt(overhead, TransactionValidator.getOverheadForTransaction(100));
    }

    function test_getOverheadForTransaction_zeroEncoding() public pure {
        uint256 overhead = TransactionValidator.getOverheadForTransaction(0);
        // Should still have base overhead
        assertGt(overhead, 0);
    }

    // ============ getTransactionBodyGasLimit Tests ============

    function test_getTransactionBodyGasLimit_sufficientGas() public pure {
        uint256 totalGasLimit = 1000000;
        uint256 encodingLength = 100;

        uint256 bodyGasLimit = TransactionValidator.getTransactionBodyGasLimit(totalGasLimit, encodingLength, false);

        // Body gas should be less than total (overhead subtracted)
        assertLt(bodyGasLimit, totalGasLimit);
        assertGt(bodyGasLimit, 0);
    }

    function test_getTransactionBodyGasLimit_zksyncOS() public pure {
        uint256 totalGasLimit = 1000000;
        uint256 encodingLength = 100;

        uint256 bodyGasLimit = TransactionValidator.getTransactionBodyGasLimit(totalGasLimit, encodingLength, true);

        // ZKsync OS has no overhead
        assertEq(bodyGasLimit, totalGasLimit);
    }

    function test_getTransactionBodyGasLimit_revertsOnInsufficientGas() public {
        uint256 totalGasLimit = 100; // Too small
        uint256 encodingLength = 10000; // Large encoding

        vm.expectRevert(TxnBodyGasLimitNotEnoughGas.selector);
        TransactionValidator.getTransactionBodyGasLimit(totalGasLimit, encodingLength, false);
    }

    function test_getTransactionBodyGasLimit_exactOverhead() public pure {
        uint256 encodingLength = 100;
        uint256 overhead = TransactionValidator.getOverheadForTransaction(encodingLength);
        uint256 totalGasLimit = overhead;

        uint256 bodyGasLimit = TransactionValidator.getTransactionBodyGasLimit(totalGasLimit, encodingLength, false);
        assertEq(bodyGasLimit, 0);
    }

    // ============ getMinimalPriorityTransactionGasLimit Tests ============

    function test_getMinimalPriorityTransactionGasLimit_nonZKsyncOS() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            100, // encodingLength
            50, // calldataLength
            0, // numberOfFactoryDependencies
            800, // l2GasPricePerPubdata
            1 gwei, // maxFeePerGas
            false // zksyncOS
        );

        assertGt(minGas, 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_zksyncOS() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            100, // encodingLength
            50, // calldataLength
            0, // numberOfFactoryDependencies
            800, // l2GasPricePerPubdata
            1 gwei, // maxFeePerGas
            true // zksyncOS
        );

        assertGt(minGas, 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_withFactoryDeps() public pure {
        uint256 minGasNoDeps = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            100,
            50,
            0,
            800,
            1 gwei,
            false
        );

        uint256 minGasWithDeps = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            100,
            50,
            5,
            800,
            1 gwei,
            false
        );

        // More factory deps should require more gas
        assertGt(minGasWithDeps, minGasNoDeps);
    }

    function test_getMinimalPriorityTransactionGasLimit_zeroMaxFeePerGas() public pure {
        // Zero max fee is possible for upgrade/service transactions
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(100, 50, 0, 800, 0, true);

        assertGt(minGas, 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_largerEncodingRequiresMoreOrEqualGas() public pure {
        uint256 minGasSmall = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            100,
            50,
            0,
            800,
            1 gwei,
            false
        );

        uint256 minGasLarge = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            1000,
            500,
            0,
            800,
            1 gwei,
            false
        );

        // Larger encoding should require at least as much gas
        assertGe(minGasLarge, minGasSmall);
    }

    // ============ validateUpgradeTransaction Tests ============

    function test_validateUpgradeTransaction_validTransaction() public pure {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        // Should not revert
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidFrom() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.from = uint256(type(uint16).max) + 1; // Invalid

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.From));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidTo() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.to = uint256(type(uint160).max) + 1; // Invalid

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.To));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroPaymaster() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.paymaster = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Paymaster));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroValue() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.value = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Value));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroMaxFeePerGas() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.maxFeePerGas = 1 gwei;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxFeePerGas));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroMaxPriorityFeePerGas() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.maxPriorityFeePerGas = 1 gwei;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxPriorityFeePerGas));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroReserved0() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved0));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidReserved1() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[1] = uint256(type(uint160).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved1));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroReserved2() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[2] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved2));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroReserved3() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[3] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved3));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonEmptySignature() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.signature = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Signature));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonEmptyPaymasterInput() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.paymasterInput = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.PaymasterInput));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_revertsOnNonEmptyReservedDynamic() public {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reservedDynamic = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.ReservedDynamic));
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function test_validateUpgradeTransaction_allowsValidReserved1() public pure {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.reserved[1] = uint256(type(uint160).max); // Max valid value

        // Should not revert
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    // ============ Fuzz Tests ============

    function testFuzz_getOverheadForTransaction(uint256 encodingLength) public pure {
        vm.assume(encodingLength < type(uint128).max); // Prevent overflow

        uint256 overhead = TransactionValidator.getOverheadForTransaction(encodingLength);
        assertGt(overhead, 0);
    }

    function testFuzz_getTransactionBodyGasLimit_zksyncOS(uint256 totalGasLimit, uint256 encodingLength) public pure {
        // ZKsync OS has no overhead, so total = body
        uint256 bodyGasLimit = TransactionValidator.getTransactionBodyGasLimit(totalGasLimit, encodingLength, true);
        assertEq(bodyGasLimit, totalGasLimit);
    }

    function testFuzz_validateUpgradeTransaction_validFrom(uint16 from) public pure {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.from = uint256(from); // Valid range

        // Should not revert
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    function testFuzz_validateUpgradeTransaction_validTo(uint160 to) public pure {
        L2CanonicalTransaction memory tx = _createValidUpgradeTransaction();
        tx.to = uint256(to); // Valid range

        // Should not revert
        TransactionValidator.validateUpgradeTransaction(tx);
    }

    // ============ Helper Functions ============

    function _createValidUpgradeTransaction() internal pure returns (L2CanonicalTransaction memory) {
        uint256[] memory factoryDeps = new uint256[](0);
        uint256[4] memory reserved;

        return
            L2CanonicalTransaction({
                txType: 254, // Upgrade tx type
                from: 0x8001, // System contract address
                to: 0x8002, // Another system contract
                gasLimit: 1000000,
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
}
