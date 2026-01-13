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

    /// @notice Emitted when the interop protocol fee is updated.
    event InteropFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    /// @notice Emitted when protocol fees are accumulated for withdrawal.
    event ProtocolFeesAccumulated(uint256 amount);

    /// @notice Emitted when protocol fees are withdrawn.
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

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

    /// @notice Returns the L1 chain ID.
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Returns the operator-set fee in base token per interop call (when useFixedFee=false).
    function interopProtocolFee() external view returns (uint256);

    /// @notice Returns the fixed fee amount in ZK tokens per interop call (when useFixedFee=true).
    function ZK_INTEROP_FEE() external view returns (uint256);

    /// @notice Returns the ZK token asset ID.
    function ZK_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Returns the accumulated protocol fees awaiting withdrawal.
    function accumulatedProtocolFees() external view returns (uint256);

    /// @notice Returns the number of bundles sent by a sender.
    function interopBundleNonce(address sender) external view returns (uint256);

    /// @notice Returns ZK token address if available, zero address otherwise.
    function getZKTokenAddress() external view returns (address);

    /// @notice Sets the base token fee per interop call (used when useFixedFee=false).
    /// @param _fee New fee amount in base token wei.
    function setInteropFee(uint256 _fee) external;

    /// @notice Allows the owner to withdraw accumulated protocol fees to a specified address.
    /// @param _to Address to send the accumulated fees to.
    function withdrawProtocolFees(address _to) external;

    /// @notice Checks if the attribute selector is supported by the InteropCenter.
    /// @param _attributeSelector The attribute selector to check.
    /// @return True if the attribute selector is supported, false otherwise.
    function supportsAttribute(bytes4 _attributeSelector) external pure returns (bool);

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external;

    /// @notice Unpauses the contract.
    function unpause() external;

    function initL2(uint256 _l1ChainId, address _owner, bytes32 _zkTokenAssetId) external;

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
