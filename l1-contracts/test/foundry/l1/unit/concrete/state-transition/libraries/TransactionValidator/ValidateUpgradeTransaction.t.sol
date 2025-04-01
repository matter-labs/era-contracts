// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";
import {InvalidUpgradeTxn, UpgradeTxVerifyParam} from "contracts/common/L1ContractErrors.sol";

contract ValidateUpgradeTxTest is TransactionValidatorSharedTest {
    function test_BasicRequest() public pure {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_RequestNotFromSystemContract() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // only system contracts (address < 2^16) are allowed to send upgrade transactions.
        testTx.from = uint256(1000000000);
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.From));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_RequestNotToSystemContract() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Now the 'to' address it too large.
        testTx.to = uint256(type(uint160).max) + 100;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.To));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_PaymasterIsNotZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Paymaster must be 0 - otherwise we revert.
        testTx.paymaster = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Paymaster));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_ValueIsNotZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Value must be 0 - otherwise we revert.
        testTx.value = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Value));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_MaxFeePerGasIsNotZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // MaxFeePerGas must be 0 - otherwise we revert.
        testTx.maxFeePerGas = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxFeePerGas));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_MaxPriorityFeePerGasIsNotZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // MaxPriorityFeePerGas must be 0 - otherwise we revert.
        testTx.maxPriorityFeePerGas = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.MaxPriorityFeePerGas));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved0IsNonZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 0 must be 0 - otherwise we revert.
        testTx.reserved[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved0));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved1IsTooLarge() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 1 must be a valid address
        testTx.reserved[1] = uint256(type(uint160).max) + 100;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved1));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved2IsNonZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 2 must be 0 - otherwise we revert.
        testTx.reserved[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved2));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved3IsNonZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 3 be 0 - otherwise we revert.
        testTx.reserved[3] = 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Reserved3));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_NonZeroSignature() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Signature must be 0 - otherwise we revert.
        testTx.signature = bytes("hello");
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.Signature));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_PaymasterInputNonZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // PaymasterInput must be 0 - otherwise we revert.
        testTx.paymasterInput = bytes("hi");
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.PaymasterInput));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_ReservedDynamicIsNonZero() public {
        L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // ReservedDynamic must be 0 - otherwise we revert.
        testTx.reservedDynamic = bytes("something");
        vm.expectRevert(abi.encodeWithSelector(InvalidUpgradeTxn.selector, UpgradeTxVerifyParam.ReservedDynamic));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }
}
