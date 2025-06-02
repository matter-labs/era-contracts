// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {InteropBundle, InteropCallStarter, L2Log, L2Message, TxStatus} from "../common/Messaging.sol";
import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesInner, L2TransactionRequestTwoBridgesOuter} from "../bridgehub/IBridgehub.sol";
import {IAssetTracker} from "../bridge/asset-tracker/IAssetTracker.sol";
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IInteropCenter {
    event InteropBundleSent(bytes32 l2l1TxHash, bytes32 interopBundleHash, InteropBundle interopBundle);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function assetTracker() external view returns (IAssetTracker);

    function setAddresses(address assetRouter, address assetTracker) external;
    /// Mailbox forwarder

    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        uint256 _baseTokenAmount,
        bytes32 _assetId,
        uint256 _amount
    ) external;

    function sendBundle(
        uint256 _destinationChainId,
        InteropCallStarter[] memory _callStarters
    ) external payable returns (bytes32);
}
