// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {IInteropCenter} from "../../bridgehub/IInteropCenter.sol";

/// @dev The encoding version used for legacy txs.
bytes1 constant LEGACY_ENCODING_VERSION = 0x00;

/// @dev The encoding version used for new txs.
bytes1 constant NEW_ENCODING_VERSION = 0x01;

/// @dev The encoding version used for txs that set the asset handler on the counterpart contract.
bytes1 constant SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION = 0x02;

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAssetRouterBase {
    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        bytes32 assetId,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        bytes32 assetId,
        bytes bridgeMintCalldata
    );

    event BridgehubWithdrawalInitiated(
        uint256 chainId,
        address indexed sender,
        bytes32 indexed assetId,
        bytes32 assetDataHash // Todo: What's the point of emitting hash?
    );

    event AssetHandlerRegisteredInitial(
        bytes32 indexed assetId,
        address indexed assetHandlerAddress,
        bytes32 indexed additionalData,
        address assetDeploymentTracker
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetAddress);

    event DepositFinalizedAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function INTEROP_CENTER() external view returns (IInteropCenter);

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterpart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(bytes32 _assetRegistrationData, address _assetHandlerAddress) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @dev We have both the legacy finalizeWithdrawal and the new finalizeDeposit functions,
    /// finalizeDeposit uses the new format. On the L2 we have finalizeDeposit with new and old formats both.
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes memory _transferData) external;

    /// @notice Initiates a transfer transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _value The `msg.value` on the target chain tx.
    /// @param _data The calldata for the second bridge deposit.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    /// @dev Data has the following abi encoding for legacy deposits:
    /// address _l1Token,
    /// uint256 _amount,
    /// address _l2Receiver
    /// for new deposits:
    /// bytes32 _assetId,
    /// bytes _transferData
    function bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) external payable;

    /// @notice Generates a calldata for calling the deposit finalization on the L2 native token contract.
    // / @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _sender The address of the deposit initiator.
    /// @param _assetId The deposited asset ID.
    /// @param _assetData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @return Returns calldata used on ZK chain.
    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) external view returns (bytes memory);

    /// @notice Routes the confirmation to nullifier for backward compatibility.
    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;
}
