// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";

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
    ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE
} from "contracts/common/Config.sol";

/// @notice Unit tests for TransactionValidator library
contract TransactionValidatorTest is Test {
    // ============ getMinimalPriorityTransactionGasLimit Tests ============

    function test_getMinimalPriorityTransactionGasLimit_zeroCalldata() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(0, 800);
        // The intrinsic native (pubdata-driven) term dominates the plain intrinsic gas here.
        assertGt(minGas, L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS);
    }

    function test_getMinimalPriorityTransactionGasLimit_calldataFloor() public pure {
        // At the minimum pubdata price, calldata cost determines the gas limit.
        uint256 baseGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(0, 1);
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(100_000, 1);
        assertEq(minGas - baseGas, L1_TX_CALLDATA_FLOOR_PRICE_L2_GAS_ZKSYNC_OS * 100_000);
    }

    // ============ validateUpgradeTransaction Tests ============

    function test_validateUpgradeTransaction_validTransaction() public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidFrom() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.from = uint256(type(uint16).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.From));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidTo() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.to = uint256(type(uint160).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.To));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroPaymaster() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.paymaster = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Paymaster));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroValue() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.value = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Value));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroMaxFeePerGas() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.maxFeePerGas = 1 gwei;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxFeePerGas));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroMaxPriorityFeePerGas() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.maxPriorityFeePerGas = 1 gwei;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxPriorityFeePerGas));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroReserved0() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.reserved[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved0));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidReserved1() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.reserved[1] = uint256(type(uint160).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved1));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroReserved2() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.reserved[2] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved2));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonZeroReserved3() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.reserved[3] = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved3));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonEmptySignature() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.signature = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Signature));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonEmptyPaymasterInput() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.paymasterInput = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.PaymasterInput));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnNonEmptyReservedDynamic() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.reservedDynamic = hex"1234";

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.ReservedDynamic));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_allowsValidReserved1() public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.reserved[1] = uint256(type(uint160).max); // Max valid value

        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    // ============ validateL1ToL2Transaction Tests ============

    function test_validateL1ToL2Transaction_success() public pure {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 10_000_000;

        TransactionValidator.validateL1ToL2Transaction(transaction, 100_000_000, 100_000);
    }

    function test_validateL1ToL2Transaction_allowsLargeTransactions() public pure {
        // If governance allows it, a transaction can use a gas limit (and pubdata) far above production values.
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        uint256 largeGasLimit = 2_000_000_000;
        transaction.gasPerPubdataByteLimit = 1;
        transaction.gasLimit = largeGasLimit;

        TransactionValidator.validateL1ToL2Transaction(transaction, largeGasLimit, largeGasLimit);
    }

    function test_validateL1ToL2Transaction_revertsIfTooMuchGas() public {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 100_000_000_000;

        vm.expectRevert(TooMuchGas.selector);
        TransactionValidator.validateL1ToL2Transaction(transaction, 1_000_000, 1_000_000);
    }

    function test_validateL1ToL2Transaction_revertsIfPubdataTooHigh() public {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 10_000_000;
        transaction.gasPerPubdataByteLimit = 1;

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

    function test_validateL1ToL2Transaction_revertsOnHugeGasPerPubdata() public {
        L2CanonicalTransaction memory transaction = _createBasicL2Transaction();
        transaction.gasLimit = 400_000;
        // The intrinsic pubdata cost overflows in getMinimalPriorityTransactionGasLimit.
        transaction.gasPerPubdataByteLimit = type(uint256).max;

        vm.expectRevert(stdError.arithmeticError);
        TransactionValidator.validateL1ToL2Transaction(transaction, 500_000, 100_000);
    }

    // ============ Fuzz Tests ============

    function testFuzz_getMinimalPriorityTransactionGasLimit_monotonicInCalldata(
        uint32 _calldataLength,
        uint32 _delta,
        uint32 _gasPerPubdata
    ) public pure {
        uint256 shorter = TransactionValidator.getMinimalPriorityTransactionGasLimit(_calldataLength, _gasPerPubdata);
        uint256 longer = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            uint256(_calldataLength) + _delta,
            _gasPerPubdata
        );
        assertGe(longer, shorter);
    }

    function testFuzz_validateUpgradeTransaction_validFrom(uint16 _from) public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.from = uint256(_from);

        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function testFuzz_validateUpgradeTransaction_validTo(uint160 _to) public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.to = uint256(_to);

        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    // ============ Helper Functions ============

    function _createValidUpgradeTransaction() internal pure returns (L2CanonicalTransaction memory) {
        uint256[] memory factoryDeps = new uint256[](0);
        uint256[4] memory reserved;

        return
            L2CanonicalTransaction({
                txType: 254, // Upgrade transaction type
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
