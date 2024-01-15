// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1Bridge {
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;
}

/// @author Matter Labs
// note we use the IL1BridgeDeprecated only to send L1<>L2 messages,
// and we use this interface so that when the switch happened the old messages could be processed
interface IL1BridgeDeprecated {
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;
}
