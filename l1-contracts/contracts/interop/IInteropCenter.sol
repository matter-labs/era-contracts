// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {
    BalanceChange,
    BundleAttributes,
    CallAttributes,
    InteropBundle,
    InteropCallStarter
} from "../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IInteropCenter {
    event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle interopBundle);

    event NewAssetRouter(address indexed oldAssetRouter, address indexed newAssetRouter);
    event NewAssetTracker(address indexed oldAssetTracker, address indexed newAssetTracker);

    /// @notice Emitted when the interop protocol fee is updated.
    event InteropFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    /// @notice Emitted when protocol fees (base token) are accumulated for the coinbase.
    /// @param coinbase Address of the block producer (block.coinbase) that earned the fees.
    /// @param amount Amount of base token accumulated (claimable via claimProtocolFees).
    event ProtocolFeesAccumulated(address indexed coinbase, uint256 amount);

    /// @notice Emitted when ZK fees are accumulated.
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

    /// @notice Returns the cached ZK token contract address.
    function zkToken() external view returns (IERC20);

    /// @notice Returns the number of bundles sent by a sender.
    function interopBundleNonce(address sender) external view returns (uint256);

    /// @notice Returns ZK token address if available, zero address otherwise.
    /// @dev View function to check ZK token availability without modifying state.
    /// @return The ZK token address or zero address if not available.
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
    /// @dev Can be set to 0 to disable base token fees for users.
    /// @dev Only callable by the bootloader as a system transaction, operator-controlled.
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

    /// @notice Initializes the InteropCenter on a fresh genesis deployment.
    /// @param _l1ChainId The chain ID of L1.
    /// @param _owner The owner address.
    /// @param _zkTokenAssetId The ZK token asset ID.
    function initL2(uint256 _l1ChainId, address _owner, bytes32 _zkTokenAssetId) external;

    /// @notice Initializes the InteropCenter during a non-genesis upgrade on an existing chain.
    /// @dev Performs the same initialization as `initL2`. A separate method is provided for
    ///      consistency with the initL2/updateL2 pattern used by other L2 system contracts
    ///      and for maintainability, so that future upgrade-specific logic can be added here.
    /// @param _l1ChainId The chain ID of L1.
    /// @param _owner The owner address.
    function updateL2(uint256 _l1ChainId, address _owner) external;

    /// @notice Forwards a transaction from the gateway to a chain mailbox (from L1).
    /// @dev Note, that `_canonicalTxHash` is provided by the chain and so should not be trusted to be unique,
    /// while the rest of the fields are trusted to be populated correctly inside the `Mailbox` of the Gateway.
    /// @param _chainId Target chain ID.
    /// @param _canonicalTxHash Canonical L1 transaction hash.
    /// @param _expirationTimestamp Deprecated, always 0.
    /// @param _balanceChange Balance change for the transaction.
    function forwardTransactionOnGatewayWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        BalanceChange memory _balanceChange
    ) external;

    /// @notice Sends an interop bundle.
    /// @param _destinationChainId Chain ID to send to. It's an ERC-7930 address that MUST have an empty address field, and encodes an EVM destination chain ID.
    /// @param _callStarters Array of call descriptors. The ERC-7930 address in each callStarter.to
    ///                      MUST have an empty ChainReference field. We assume all of the calls should go to the _destinationChainId,
    ///                      so specifying the chain ID in _callStarters is redundant.
    /// @param _bundleAttributes Attributes of the bundle.
    /// @return bundleHash Hash of the sent bundle.
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable returns (bytes32 bundleHash);

    /// @notice Parses the attributes of the call or bundle.
    /// @param _attributes ERC-7786 Attributes of the call or bundle.
    /// @param _restriction Restriction for parsing attributes.
    function parseAttributes(
        bytes[] calldata _attributes,
        AttributeParsingRestrictions _restriction
    ) external pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes);
}
