// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {InteropCallStarter, InteropCall, BundleMetadata, InteropBundle, InteropTrigger, GasFields, InteropCallRequest} from "contracts/common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IInteropCenter {
    function setAddresses(address assetRouter) external;
    /// Mailbox forwarder

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function requestL2TransactionDirectSender(
        address _sender,
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function requestL2TransactionTwoBridgesSender(
        address _sender,
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function forwardTransactionOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external;

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);


    function requestInterop(
        uint256 _destinationChainId,
        InteropCallStarter[] memory _feePaymentCallStarters,
        InteropCallRequest[] memory _feePaymentDirectCalls,
        InteropCallStarter[] memory _executionCallStarters,
        InteropCallRequest[] memory _executionDirectCalls,
        GasFields memory _gasFields
    ) external payable returns (bytes32);

    function addCallToBundleFromRequest(bytes32 _bundleId, uint256 _value, L2TransactionRequestTwoBridgesInner memory _request) external;
}
