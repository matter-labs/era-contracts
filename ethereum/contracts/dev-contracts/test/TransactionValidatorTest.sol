// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../zksync/libraries/TransactionValidator.sol";
import "../../zksync/interfaces/IMailbox.sol";

contract TransactionValidatorTest {
    function validateL1ToL2Transaction(
        IMailbox.L2CanonicalTransaction memory _transaction,
        uint256 _priorityTxMaxGasLimit
    ) external pure {
        TransactionValidator.validateL1ToL2Transaction(_transaction, abi.encode(_transaction), _priorityTxMaxGasLimit);
    }

    function validateUpgradeTransaction(IMailbox.L2CanonicalTransaction memory _transaction) external pure {
        TransactionValidator.validateUpgradeTransaction(_transaction);
    }
}
