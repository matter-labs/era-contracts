// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title L1 Bridge contract legacy interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1BridgeLegacy {
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 txHash);
}
