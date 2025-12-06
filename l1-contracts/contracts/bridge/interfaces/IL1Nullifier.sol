// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";
import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";
import {IL1ERC20Bridge} from "./IL1ERC20Bridge.sol";
import {FinalizeL1DepositParams, ConfirmTransferResultData} from "../../common/Messaging.sol";

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

    event TransientSettlementLayerSet(uint256 indexed settlementLayerChainId);

    function isWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex
    ) external view returns (bool);

    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    function finalizeDeposit(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    function l1AssetRouter() external view returns (IL1AssetRouter);

    function legacyBridge() external view returns (IL1ERC20Bridge);

    function depositHappened(uint256 _chainId, bytes32 _l2TxHash) external view returns (bytes32);

    function bridgehubConfirmL2TransactionForwarded(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function l1NativeTokenVault() external view returns (IL1NativeTokenVault);

    function setL1NativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external;

    function setL1AssetRouter(address _l1AssetRouter) external;

    function chainBalance(uint256 _chainId, address _token) external view returns (uint256);

    function l2BridgeAddress(uint256 _chainId) external view returns (address);

    function transferTokenToNTV(address _token) external;

    function nullifyChainBalanceByNTV(uint256 _chainId, address _token) external;

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

    /// @notice Legacy function to finalize withdrawal via the same
    /// interface as the old L1SharedBridge.
    /// @dev Note, that we need to keep this interface, since the `L2AssetRouter`
    /// will continue returning the previous address as the `l1SharedBridge`. The value
    /// returned by it is used in the SDK for finalizing withdrawals.
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

    /// @notice When verifying recursive proofs, we mark the transient settlement layer,
    /// this function retrieves the currently stored transient settlement layer chain ID.
    /// @dev The transient settlement layer is cleared at the end of each transaction.
    /// @dev Note, that it is hard assumption that must be enforced by all the users of this function:
    /// Any operations that reads this value, must be preceded by a successful invocation of L1Nullifier
    /// that has set this value. Otherwise, it is possible that the same value is reused multiple times.
    /// @return The chain ID of the settlement layer that processed the current proof, or 0 if none is set.
    function getTransientSettlementLayer() external view returns (uint256, uint256);
}
