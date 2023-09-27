// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @author Matter Labs
interface IL1Bridge {
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;
}
