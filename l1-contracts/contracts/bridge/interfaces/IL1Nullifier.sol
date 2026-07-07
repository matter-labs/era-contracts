// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";
import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";
import {ConfirmTransferResultData} from "../../common/Messaging.sol";

/// @dev Transient storage slot for storing the settlement layer chain ID during proof verification.
/// @dev This slot is used to temporarily store which settlement layer is processing the current proof,
/// @dev and is cleared at the end of each transaction.
uint256 constant TRANSIENT_SETTLEMENT_LAYER_SLOT = uint256(keccak256("TRANSIENT_SETTLEMENT_LAYER_SLOT")) - 1;

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1Nullifier {
    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    /// @notice Historical record of withdrawals finalized through this contract before v31. From v31
    /// onwards withdrawals are executed by the `L1InteropHandler` and this mapping is no longer written.
    function isWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex
    ) external view returns (bool);

    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    function l1AssetRouter() external view returns (IL1AssetRouter);

    function depositHappened(uint256 _chainId, bytes32 _l2TxHash) external view returns (bytes32);

    function bridgehubConfirmL2TransactionForwarded(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function l1NativeTokenVault() external view returns (IL1NativeTokenVault);

    function setL1NativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external;

    function setL1AssetRouter(address _l1AssetRouter) external;

    /// @notice Confirms the result of a deposit, whether it was successful or not.
    /// @dev This function is used to confirm the migration of a chain to Gateway.
    /// @param _confirmTransferResultData The data to confirm the deposit result.
    function bridgeConfirmTransferResult(ConfirmTransferResultData calldata _confirmTransferResultData) external;

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
}
