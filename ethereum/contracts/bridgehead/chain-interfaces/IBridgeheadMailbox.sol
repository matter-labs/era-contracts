// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import {L2Log, L2Message} from "../chain-deps/ChainStorage.sol";
import "./IChainBase.sol";
import "../../common/Messaging.sol";
import "./IMailboxEvents.sol";

interface IBridgeheadMailbox is IMailboxEvents, IChainBase {
    function isEthWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2MessageIndex,
        uint256 _l2TxNumberInBlock
    ) external view returns (bool);

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    function finalizeEthWithdrawal(
        uint256 _chainId,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

    function requestL2Transaction(
        uint256 _chainId,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable returns (bytes32 canonicalTxHash);

    function requestL2TransactionProof(
        uint256 _chainId,
        WritePriorityOpParams memory _params,
        bytes calldata _calldata,
        bytes[] calldata _factoryDeps,
        bool _isFree
    ) external returns (bytes32 canonicalTxHash);

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);
}
