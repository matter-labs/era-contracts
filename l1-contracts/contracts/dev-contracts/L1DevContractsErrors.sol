// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

error WithdrawFailed();

error MsgValueNotEqualToAmount();

error WrongWithdrawAmount();

error MsgValueIsLessThenZeroForBridgehubDeposit();

error WithdrawAndDepositAmountsMismatch();

error LegacyBridgeAlreadySet();

error LegacyBridgeZero();

error OnlyOneCallSupported();

error ConstructorForwarderFailed();

error ForwarderFailed();

error MulticallFailed();

error Multicall3CallFailed();

error Multicall3ValueMismatch();

error Weth9WithdrawMoreThenBalance();

error Weth9WithdrawMoreThenAllowance();

error DummyExecutorShouldRevertOnCommitBatches();

error DummyExecutorInvalidLastCommittedBatchNumber();

error DummyExecutorInvalidBatchNumber();

error DummyExecutorShouldRevertOnProveBatches();

error DummyExecutorInvalidPreviousBatchNumber();

error DummyExecutorCanProveOnlyOneBatch();

error DummyExecutorCannotProveBatchOutOfOrder();

error DummyExecutorProveMoreBatchesThanWereCommitted();

error DummyExecutorShouldRevertOnExecuteBatches();

error DummyExecutorCannotExecuteBatchesMoreThanCommittedAndProvenCurrently();

error DummyExecutorTheLastCommittedBatchIsLessThanNewLastBatch();

error OnlyOwner();