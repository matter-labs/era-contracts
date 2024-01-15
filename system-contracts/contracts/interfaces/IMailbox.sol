// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IMailbox {
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;
}
