// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    InvalidUpgradeTxn,
    PubdataGreaterThanLimit,
    TooMuchGas,
    UpgradeTxVerifyParam,
    ValidateTxnNotEnoughGas
} from "contracts/common/L1ContractErrors.sol";
import {
    L1_TX_CALLDATA_FLOOR_PRICE_L2_GAS_ZKSYNC_OS,
    L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE
} from "contracts/common/Config.sol";

/// @notice Unit tests for TransactionValidator library
contract TransactionValidatorTest is Test {
    // ============ getMinimalPriorityTransactionGasLimit Tests ============

    function test_getMinimalPriorityTransactionGasLimit_zeroCalldata() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(0, 800);
        // The intrinsic native (pubdata-driven) term dominates the plain intrinsic gas here.
        assertTrue(minGas >= L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS);
    }

    function test_getMinimalPriorityTransactionGasLimit_calldataFloor() public pure {
        // With free pubdata, the calldata floor price is the marginal cost per byte.
        uint256 baseGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(0, 1);
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(100_000, 1);
        assertEq(minGas - baseGas, L1_TX_CALLDATA_FLOOR_PRICE_L2_GAS_ZKSYNC_OS * 100_000);
    }

    function testFuzz_getMinimalPriorityTransactionGasLimit_monotonic(
        uint32 calldataLength,
        uint32 delta,
        uint32 gasPerPubdata
    ) public pure {
        vm.assume(gasPerPubdata > 0);
        uint256 shorter = TransactionValidator.getMinimalPriorityTransactionGasLimit(calldataLength, gasPerPubdata);
        uint256 longer = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            uint256(calldataLength) + delta,
            gasPerPubdata
        );
        // Longer calldata can never lower the minimal gas limit.
        assertTrue(longer >= shorter);
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

    function test_validateL1ToL2Transaction_success() public pure {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 10_000_000;

        // Should not revert.
        TransactionValidator.validateL1ToL2Transaction(transaction, 100_000_000, 100_000);
    }

    function test_validateL1ToL2Transaction_revertsIfTooMuchGas() public {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 100_000_000_000; // Very high gas limit

        vm.expectRevert(TooMuchGas.selector);
        TransactionValidator.validateL1ToL2Transaction(
            transaction,
            1_000_000, // priority tx max gas limit (much lower)
            1_000_000 // priority tx max pubdata
        );
    }

    function test_validateL1ToL2Transaction_revertsIfPubdataTooHigh() public {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 10_000_000;
        transaction.gasPerPubdataByteLimit = 1; // Very low pubdata price = high pubdata amount

        // ZKsync OS has no batch overhead: the whole gas limit counts towards pubdata.
        uint256 expectedPubdata = transaction.gasLimit / transaction.gasPerPubdataByteLimit;

        vm.expectRevert(abi.encodeWithSelector(PubdataGreaterThanLimit.selector, 1000, expectedPubdata));
        TransactionValidator.validateL1ToL2Transaction(transaction, 100_000_000, 1000);
    }

    function test_validateL1ToL2Transaction_revertsIfBelowIntrinsicGas() public {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        // Below even the plain intrinsic gas cost, whatever the native term evaluates to.
        transaction.gasLimit = L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS - 1;

        vm.expectRevert(ValidateTxnNotEnoughGas.selector);
        TransactionValidator.validateL1ToL2Transaction(transaction, 100_000_000, 100_000);
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
                txType: ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE,
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
                txType: ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE,
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
