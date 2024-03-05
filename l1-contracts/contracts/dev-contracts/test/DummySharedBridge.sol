// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract DummySharedBridge {
    bytes32 dummyL2DepositTxHash;

    address l1ReceiverReturnInFinalizeWithdrawal;
    address l1TokenReturnInFinalizeWithdrawal;
    uint256 amountReturnInFinalizeWithdrawal;

    constructor(bytes32 _dummyL2DepositTxHash) {
        dummyL2DepositTxHash = _dummyL2DepositTxHash;
    }

    function setDataToBeReturnedInFinalizeWithdrawal(address _l1Receiver, address _l1Token, uint256 _amount) external {
        l1ReceiverReturnInFinalizeWithdrawal = _l1Receiver;
        l1TokenReturnInFinalizeWithdrawal = _l1Token;
        amountReturnInFinalizeWithdrawal = _amount;
    }

    function depositLegacyErc20Bridge(
        address _msgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash) {
        txHash = dummyL2DepositTxHash;
    }

    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external {}

    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external returns (address l1Receiver, address l1Token, uint256 amount) {
        l1Receiver = l1ReceiverReturnInFinalizeWithdrawal;
        l1Token = l1TokenReturnInFinalizeWithdrawal;
        amount = amountReturnInFinalizeWithdrawal;
    }
}
