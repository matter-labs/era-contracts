// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {BundleMetadata, GasFields, InteropBundle, InteropCall, InteropCallRequest, InteropCallStarter, InteropTrigger, L2Log, L2Message, TxStatus} from "../common/Messaging.sol";
import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesInner, L2TransactionRequestTwoBridgesOuter} from "./IBridgehub.sol";
import {IAssetTracker} from "../bridge/asset-tracker/IAssetTracker.sol";
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IInteropCenter {
    event InteropBundleSent(bytes32 l2l1TxHash, bytes32 interopBundleHash, InteropBundle interopBundle);
    event InteropTriggerSent(bytes32 l2l11TxHash, InteropTrigger _interopTrigger);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function assetTracker() external view returns (IAssetTracker);

    function setAddresses(address assetRouter, address assetTracker) external;
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

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);

    function addCallToBundleFromRequest(
        bytes32 _bundleId,
        uint256 _value,
        L2TransactionRequestTwoBridgesInner memory _request
    ) external;

    function startBundle(uint256 _destinationChainId) external returns (bytes32 bundleId);

    function addCallToBundle(bytes32 _bundleId, InteropCallRequest memory _interopCallRequest) external;

    function finishAndSendBundle(
        bytes32 _bundleId,
        address _executionAddress
    ) external payable returns (bytes32 interopBundleHash);

    function sendInteropTrigger(InteropTrigger memory _interopTrigger) external returns (bytes32 canonicalTxHash);

    function requestInterop(
        uint256 _destinationChainId,
        address _executionAddress,
        InteropCallStarter[] memory _feePaymentCallStarters,
        InteropCallStarter[] memory _executionCallStarters,
        GasFields memory _gasFields
    ) external payable returns (bytes32 canonicalTxHash);

    function requestInteropSingleCall(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function requestInteropSingleDirectCall(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        uint256 _baseTokenAmount,
        bytes32 _assetId,
        uint256 _amount
    ) external;
}
