// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {InvalidUpgradeTxn, UpgradeTxVerifyParam} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for TransactionValidator library
contract TransactionValidatorTest is Test {
    // ============ getMinimalPriorityTransactionGasLimit Tests ============

    function test_getMinimalPriorityTransactionGasLimit_basicValues() public pure {
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            50, // calldataLength
            800 // l2GasPricePerPubdata
        );

        assertGt(minGas, 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_zeroMaxFeePerGas() public pure {
        // Zero max fee is possible for upgrade/service transactions
        uint256 minGas = TransactionValidator.getMinimalPriorityTransactionGasLimit(50, 800);

        assertGt(minGas, 0);
    }

    function test_getMinimalPriorityTransactionGasLimit_largerCalldataRequiresMoreOrEqualGas() public pure {
        uint256 minGasSmall = TransactionValidator.getMinimalPriorityTransactionGasLimit(50, 800);

        uint256 minGasLarge = TransactionValidator.getMinimalPriorityTransactionGasLimit(500, 800);

        // Larger calldata should require at least as much gas
        assertGe(minGasLarge, minGasSmall);
    }

    // ============ validateUpgradeTransaction Tests ============

    function test_validateUpgradeTransaction_validTransaction() public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        // Should not revert
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidFrom() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.from = uint256(type(uint16).max) + 1; // Invalid

        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.From));
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function test_validateUpgradeTransaction_revertsOnInvalidTo() public {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.to = uint256(type(uint160).max) + 1; // Invalid

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

        // Should not revert
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    // ============ Fuzz Tests ============

    function testFuzz_getMinimalPriorityTransactionGasLimit_monotonicInCalldata(
        uint32 calldataLength,
        uint32 delta,
        uint32 gasPerPubdata
    ) public pure {
        uint256 shorter = TransactionValidator.getMinimalPriorityTransactionGasLimit(calldataLength, gasPerPubdata);
        uint256 longer = TransactionValidator.getMinimalPriorityTransactionGasLimit(
            uint256(calldataLength) + delta,
            gasPerPubdata
        );
        assertGe(longer, shorter);
    }

    function testFuzz_validateUpgradeTransaction_validFrom(uint16 from) public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.from = uint256(from); // Valid range

        // Should not revert
        TransactionValidator.validateUpgradeTransaction(transaction);
    }

    function testFuzz_validateUpgradeTransaction_validTo(uint160 to) public pure {
        L2CanonicalTransaction memory transaction = _createValidUpgradeTransaction();
        transaction.to = uint256(to); // Valid range

        // Should not revert
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
}
