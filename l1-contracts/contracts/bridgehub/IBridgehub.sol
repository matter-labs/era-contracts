// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IL1Bridge} from "../bridge/interfaces/IL1Bridge.sol";
import "../common/Messaging.sol";
import "../state-transition/IStateTransitionManager.sol";
import "../state-transition/libraries/Diamond.sol";

interface IBridgehub {
    /// Getters
    function stateTransitionManagerIsRegistered(address _stateTransitionManager) external view returns (bool);

    function stateTransitionManager(uint256 _chainId) external view returns (address);

    function tokenIsRegistered(address _baseToken) external view returns (bool);

    function baseToken(uint256 _chainId) external view returns (address);

    function wethBridge() external view returns (IL1Bridge);

    function tokenBridgeIsRegistered(address _baseTokenBridge) external view returns (bool);

    function baseTokenBridge(uint256 _chainId) external view returns (address);

    function getZkSyncStateTransition(uint256 _chainId) external view returns (address);

    /// Mailbox forwarder

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    struct L2TransactionRequest {
        uint256 chainId;
        address payer;
        address l2Contract;
        uint256 mintValue;
        uint256 l2Value;
        bytes l2Calldata;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdataByteLimit;
        bytes[] factoryDeps;
        address refundRecipient;
    }

    function requestL2Transaction(
        L2TransactionRequest memory _request
    ) external payable returns (bytes32 canonicalTxHash);

    // function requestL2TransactionSkipDeposit(
    //     uint256 _chainId,
    //     address _contractL2,
    //     uint256 _mintValue,
    //     uint256 _l2Value,
    //     bytes calldata _calldata,
    //     uint256 _l2GasLimit,
    //     uint256 _l2GasPerPubdataByteLimit,
    //     bytes[] calldata _factoryDeps,
    //     address _refundRecipient
    // ) external returns (bytes32 canonicalTxHash);

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);

    //// Registry

    function newChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        address _baseTokenBridge,
        uint256 _salt,
        address _governor,
        bytes calldata _initData
    ) external returns (uint256 chainId);

    function newStateTransitionManager(address _stateTransitionManager) external;

    function newToken(address _token) external;

    function newTokenBridge(address _tokenBridge) external;

    function setWethBridge(address _wethBridge) external;

    event NewChain(uint64 indexed chainId, address stateTransitionManager, address indexed chainGovernance);
}
