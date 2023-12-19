// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../common/Messaging.sol";
import "../../state-transition/state-transition-interfaces/IZkSyncStateTransition.sol";
import "../../common/libraries/Diamond.sol";


interface IBridgehub {

    /// Getters
    function getName() external view returns (string memory);

    function governor() external view returns (address);

    function stateTransitionIsRegistered(address _stateTransition) external view returns (bool);

    function stateTransition(uint256 _chainId) external view returns (address);

    function tokenIsRegistered(address _baseToken) external view returns (bool);

    function baseToken(uint256 _chainId) external view returns (address);

    function tokenBridgeIsRegistered(address _baseTokenBridge) external view returns (bool);

    function baseTokenBridge(uint256 _chainId) external view returns (address);

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

    function requestL2Transaction(
        uint256 _chainId,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
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
        address _stateTransition,
        address _baseToken,
        address _baseTokenBridge,
        uint256 _salt,
        address _governor,
        bytes calldata _initData
    ) external returns (uint256 chainId);

    function newStateTransition(address _stateTransition) external;

    event NewChain(uint64 indexed chainId, address stateTransition, address indexed chainGovernance);
}
