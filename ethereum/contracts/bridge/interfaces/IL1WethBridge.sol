// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @author Matter Labs
interface IL1WethBridge {
    struct FinalizeWithdrawalL2MessageIndexes {
        uint256 ethL2MessageIndex;
        uint256 wethL2MessageIndex;
    }

    struct FinalizeWithdrawalMessages {
        bytes ethMessage;
        bytes wethMessage;
    }

    struct FinalizeWithdrawalMerkleProofs {
        bytes32[] ethProof;
        bytes32[] wethProof;
    }

    event DepositInitiated(address indexed from, address indexed to, address indexed l1Token, uint256 amount);

    event WithdrawalFinalized(address indexed to, address indexed l1Token, uint256 amount);

    event ClaimedFailedDeposit(address indexed to, address indexed l1Token, uint256 amount);

    function isWithdrawalFinalized(uint256 _l2BlockNumber, uint256 _l2MessageIndex) external view returns (bool);

    function deposit(
        address _l2Receiver,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 txHash);

    function claimFailedDeposit(
        address _depositSender,
        bytes32 _l2TxHash,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes32[] calldata _merkleProof
    ) external;

    function finalizeWithdrawal(
        uint256 _l2BlockNumber,
        FinalizeWithdrawalL2MessageIndexes calldata _l2MessageIndexes,
        uint16 _l2TxNumberInBlock,
        FinalizeWithdrawalMessages calldata _messages,
        FinalizeWithdrawalMerkleProofs calldata _merkleProofs
    ) external;
}
