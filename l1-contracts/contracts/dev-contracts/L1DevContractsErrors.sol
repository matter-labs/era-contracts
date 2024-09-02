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

DummyExecutorShouldRevertOnCommitBatches();
DummyExecutorInvalidLastCommittedBatchNumber();
DummyExecutorInvalidBatchNumber();
DummyExecutorShouldRevertOnProveBatches();
DummyExecutorInvalidPreviousBatchNumber();
DummyExecutorCanProveOnlyOneBatch();
DummyExecutorCannotProveBatchOutOfOrder();
DummyExecutorProveMoreBatchesThanWereCommitted();
DummyExecutorShouldRevertOnExecuteBatches();
DummyExecutorCannotExecuteBatchesMoreThanCommittedAndProvenCurrently();
DummyExecutorTheLastCommittedBatchIsLessThanNewLastBatch();