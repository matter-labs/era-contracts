// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Transaction} from "../libraries/TransactionHelper.sol";

interface IBootloaderUtilities {
    function getTransactionHashes(
        Transaction calldata _transaction
    ) external view returns (bytes32 txHash, bytes32 signedTxHash);
}
