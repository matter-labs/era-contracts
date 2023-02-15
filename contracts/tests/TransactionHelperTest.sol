// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../libraries/TransactionHelper.sol";

contract TransactionHelperTest {
    using TransactionHelper for Transaction;

    function encodeHash(Transaction calldata _transaction) public view returns (bytes32 resultHash) {
        resultHash = _transaction.encodeHash();
    }
}
