// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../libraries/TransactionHelper.sol";

interface IBootloaderUtilities {
    function getTransactionHashes(
        Transaction calldata _transaction
    ) external view returns (bytes32 txHash, bytes32 signedTxHash);
}
