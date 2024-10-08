// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "./IL1Nullifier.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";
import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";

/// @title L1 Bridge contract legacy interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Legacy Bridge interface before ZK chain migration, used for backward compatibility with ZKsync Era
interface IL1ERC20Bridge {
    event DepositInitiated(
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address indexed to,
        address l1Token,
        uint256 amount
    );

    event WithdrawalFinalized(address indexed to, address indexed l1Token, uint256 amount);

    event ClaimedFailedDeposit(address indexed to, address indexed l1Token, uint256 amount);

    function isWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool);

    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash);

    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 txHash);

    function claimFailedDeposit(
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

    function l2TokenAddress(address _l1Token) external view returns (address);

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_ASSET_ROUTER() external view returns (IL1AssetRouter);

    function L1_NATIVE_TOKEN_VAULT() external view returns (IL1NativeTokenVault);

    function l2TokenBeacon() external view returns (address);

    function l2Bridge() external view returns (address);

    function depositAmount(
        address _account,
        address _l1Token,
        bytes32 _depositL2TxHash
    ) external view returns (uint256 amount);
}
