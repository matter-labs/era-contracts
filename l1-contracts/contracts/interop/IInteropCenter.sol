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

    /// @notice Emitted when protocol fees (base token) are collected and sent to the coinbase.
    /// @param recipient Address that received the fees (block.coinbase).
    /// @param amount Total amount of base token collected.
    event ProtocolFeesCollected(address indexed recipient, uint256 amount);

    /// @notice Emitted when fixed ZK fees are collected from a user and sent to the coinbase.
    /// @param payer Address that paid the fees.
    /// @param recipient Address that received the fees (block.coinbase).
    /// @param amount Total amount of ZK tokens collected.
    event FixedZKFeesCollected(address indexed payer, address indexed recipient, uint256 amount);

    /// @notice Emitted when protocol fees (base token) transfer to coinbase failed and fees are accumulated.
    /// @param coinbase Address of the block producer (block.coinbase) that earned the fees.
    /// @param amount Amount of base token accumulated (claimable via claimProtocolFees).
    event ProtocolFeesAccumulated(address indexed coinbase, uint256 amount);

    /// @notice Emitted when ZK fees transfer to coinbase failed and fees are accumulated.
    /// @param payer Address that paid the fees.
    /// @param coinbase Address of the block producer (block.coinbase) that earned the fees.
    /// @param amount Amount of ZK tokens accumulated (claimable via claimZKFees).
    event FixedZKFeesAccumulated(address indexed payer, address indexed coinbase, uint256 amount);

    /// @notice Emitted when a coinbase claims their accumulated protocol fees (base token).
    /// @param coinbase Address of the coinbase claiming the fees.
    /// @param receiver Address that received the fees.
    /// @param amount Amount of base token claimed.
    event ProtocolFeesClaimed(address indexed coinbase, address indexed receiver, uint256 amount);

    /// @notice Emitted when a coinbase claims their accumulated ZK fees.
    /// @param coinbase Address of the coinbase claiming the fees.
    /// @param receiver Address that received the fees.
    /// @param amount Amount of ZK tokens claimed.
    event ZKFeesClaimed(address indexed coinbase, address indexed receiver, uint256 amount);

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

    /// @notice Returns the number of bundles sent by a sender.
    function interopBundleNonce(address sender) external view returns (uint256);

    /// @notice Returns ZK token address if available, zero address otherwise.
    function getZKTokenAddress() external view returns (address);

    /// @notice Returns the accumulated protocol fees (base token) for a coinbase.
    /// @param coinbase Address of the coinbase.
    /// @return Amount of accumulated base token fees.
    function accumulatedProtocolFees(address coinbase) external view returns (uint256);

    /// @notice Returns the accumulated ZK fees for a coinbase.
    /// @param coinbase Address of the coinbase.
    /// @return Amount of accumulated ZK token fees.
    function accumulatedZKFees(address coinbase) external view returns (uint256);

    /// @notice Sets the base token fee per interop call (used when useFixedFee=false).
    /// @param _fee New fee amount in base token wei.
    function setInteropFee(uint256 _fee) external;

    /// @notice Allows a coinbase to claim their accumulated protocol fees (base token).
    /// @dev Transfers all accumulated base token fees to the specified receiver.
    /// @param _receiver Address to receive the fees.
    function claimProtocolFees(address _receiver) external;

    /// @notice Allows a coinbase to claim their accumulated ZK fees.
    /// @dev Transfers all accumulated ZK token fees to the specified receiver.
    /// @param _receiver Address to receive the fees.
    function claimZKFees(address _receiver) external;

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
