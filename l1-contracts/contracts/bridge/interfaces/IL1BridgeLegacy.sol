// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title L1 Bridge contract legacy interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice legacy before bridgehub, only used for Era
interface IL1BridgeLegacy {
    event DepositInitiated(
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address indexed to,
        address l1Token,
        uint256 amount
    );

    event WithdrawalFinalized(address indexed to, address indexed l1Token, uint256 amount);

    event ClaimedFailedDeposit(address indexed to, address indexed l1Token, uint256 amount);

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

    function l2TokenAddress(address _l1Token) external view returns (address);

    function l2TokenBeacon() external view returns (address);

    function l2Bridge() external view returns (address);

    function depositAmount(
        address _account,
        address _l1Token,
        bytes32 _depositL2TxHash
    ) external returns (uint256 amount);
}
