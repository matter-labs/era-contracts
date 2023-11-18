// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/libraries/TransactionValidator.sol";
import "../../bridgehub/bridgehub-interfaces/IBridgehubMailbox.sol";

import "../../common/Messaging.sol";

contract TransactionValidatorTest {
    function validateL1ToL2Transaction(
        L2CanonicalTransaction memory _transaction,
        uint256 _priorityTxMaxGasLimit
    ) external pure {
        TransactionValidator.validateL1ToL2Transaction(_transaction, abi.encode(_transaction), _priorityTxMaxGasLimit);
    }

    function validateUpgradeTransaction(L2CanonicalTransaction memory _transaction) external pure {
        TransactionValidator.validateUpgradeTransaction(_transaction);
    }
}
