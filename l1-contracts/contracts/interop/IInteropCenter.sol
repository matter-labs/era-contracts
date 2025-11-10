// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {BalanceChange, InteropBundle, InteropCallStarter} from "../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IInteropCenter {
    event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle interopBundle);

    event NewAssetRouter(address indexed oldAssetRouter, address indexed newAssetRouter);
    event NewAssetTracker(address indexed oldAssetTracker, address indexed newAssetTracker);

    /// @notice Restrictions for parsing attributes.
    /// @param OnlyInteropCallValue: Only attribute for interop call value is allowed.
    /// @param OnlyCallAttributes: Only call attributes are allowed.
    /// @param OnlyBundleAttributes: Only bundle attributes are allowed.
    /// @param CallAndBundleAttributes: Both call and bundle attributes are allowed.
    enum AttributeParsingRestrictions {
        OnlyInteropCallValue,
        OnlyCallAttributes,
        OnlyBundleAttributes,
        CallAndBundleAttributes
    }

    function initL2(uint256 _l1ChainId, address _owner) external;

    /// Mailbox forwarder

    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        BalanceChange memory _balanceChange
    ) external;

    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable returns (bytes32);
}
