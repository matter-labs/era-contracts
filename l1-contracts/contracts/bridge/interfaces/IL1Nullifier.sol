// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";

/// @param chainId The chain ID of the transaction to check.
/// @param l2BatchNumber The L2 batch number where the withdrawal was processed.
/// @param l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
/// @param l2sender The address of the message sender on L2 (base token system contract address or asset handler)
/// @param l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
/// @param message The L2 withdraw data, stored in an L2 -> L1 message.
/// @param merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
struct FinalizeWithdrawalParams {
    uint256 chainId;
    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    address l2Sender;
    uint16 l2TxNumberInBatch;
    bytes message;
    bytes32[] merkleProof;
}

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1Nullifier {
    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

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

    function finalizeWithdrawalLegacyContracts(
        FinalizeWithdrawalParams calldata _finalizeWithdrawalParams
    ) external returns (address l1Receiver, address l1Token, uint256 amount);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function legacyBridge() external view returns (address);

    function depositHappened(uint256 _chainId, bytes32 _l2TxHash) external view returns (bytes32);

    function bridgehubConfirmL2TransactionForwarded(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function hyperbridgingEnabled(uint256 _chainId) external view returns (bool);

    function l1NativeTokenVault() external view returns (IL1NativeTokenVault);

    function setL1NativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external;

    function setL1AssetRouter(address _l1AssetRouter) external;

    function chainBalance(uint256 _chainId, address _token) external view returns (uint256);

    function transferTokenToNTV(address _token) external;

    function nullifyChainBalanceByNTV(uint256 _chainId, address _token) external;
}
