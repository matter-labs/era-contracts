// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehubBase.sol";
import {IL1SharedBridgeLegacy} from "../interfaces/IL1SharedBridgeLegacy.sol";
import {IL1ERC20BridgeLegacy} from "../interfaces/IL1ERC20BridgeLegacy.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter is IAssetRouterBase, IL1SharedBridgeLegacy {
    event BridgehubMintData(bytes bridgeMintData);

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event ClaimedFailedDepositAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    event AssetDeploymentTrackerSet(
        bytes32 indexed assetId,
        address indexed assetDeploymentTracker,
        bytes32 indexed additionalData
    );

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_WETH_TOKEN() external view returns (address);

    function ETH_TOKEN_ASSET_ID() external view returns (bytes32);

    function nativeTokenVault() external view returns (INativeTokenVaultBase);

    function setAssetDeploymentTracker(bytes32 _assetRegistrationData, address _assetDeploymentTracker) external;

    function setNativeTokenVault(INativeTokenVaultBase _nativeTokenVault) external;

    function setL1Erc20Bridge(IL1ERC20BridgeLegacy _legacyBridge) external;  //TODO remove after SDK changes

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which the deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external;

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    /// @notice Transfers funds to Native Token Vault, if the asset is registered with it. Does nothing for ETH or non-registered tokens.
    /// @dev assetId is not the padded address, but the correct encoded id (NTV stores respective format for IDs)
    /// @param _amount The asset amount to be transferred to native token vault.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    function transferFundsToNTV(bytes32 _assetId, uint256 _amount, address _originalCaller) external returns (bool);

    /// @notice Finalize the withdrawal and release funds
    /// @param _chainId The chain ID of the transaction to check
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

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

    /// @notice Routes the confirmation to nullifier for backward compatibility.
    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function isWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex
    ) external view returns (bool);
}
