pragma solidity 0.8.20;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";
import {IMailbox} from "solpp/zksync/interfaces/IMailbox.sol";
import {TransactionValidator} from "solpp/zksync/libraries/TransactionValidator.sol";

contract ValidateUpgradeTxTest is TransactionValidatorSharedTest {
    function test_BasicRequest() public pure {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_RequestNotFromSystemContract() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // only system contracts (address < 2^16) are allowed to send upgrade transactions.
        testTx.from = uint256(1000000000);
        vm.expectRevert(bytes("ua"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_RequestNotToSystemContract() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Now the 'to' address it too large.
        testTx.to = uint256(type(uint160).max) + 100;
        vm.expectRevert(bytes("ub"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_PaymasterIsNotZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Paymaster must be 0 - otherwise we revert.
        testTx.paymaster = 1;
        vm.expectRevert(bytes("uc"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_ValueIsNotZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Value must be 0 - otherwise we revert.
        testTx.value = 1;
        vm.expectRevert(bytes("ud"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved0IsNonZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 0 must be 0 - otherwise we revert.
        testTx.reserved[0] = 1;
        vm.expectRevert(bytes("ue"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved1IsTooLarge() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 1 must be a valid address
        testTx.reserved[1] = uint256(type(uint160).max) + 100;
        vm.expectRevert(bytes("uf"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved2IsNonZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 2 must be 0 - otherwise we revert.
        testTx.reserved[2] = 1;
        vm.expectRevert(bytes("ug"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_Reserved3IsNonZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // reserved 3 be 0 - otherwise we revert.
        testTx.reserved[3] = 1;
        vm.expectRevert(bytes("uo"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_NonZeroSignature() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // Signature must be 0 - otherwise we revert.
        testTx.signature = bytes("hello");
        vm.expectRevert(bytes("uh"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_PaymasterInputNonZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // PaymasterInput must be 0 - otherwise we revert.
        testTx.paymasterInput = bytes("hi");
        vm.expectRevert(bytes("ul"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }

    function test_RevertWhen_ReservedDynamicIsNonZero() public {
        IMailbox.L2CanonicalTransaction memory testTx = createUpgradeTransaction();
        // ReservedDynamic must be 0 - otherwise we revert.
        testTx.reservedDynamic = bytes("something");
        vm.expectRevert(bytes("um"));
        TransactionValidator.validateUpgradeTransaction(testTx);
    }
}
