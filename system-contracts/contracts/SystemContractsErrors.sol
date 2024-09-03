// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

error UpgradeTransactionMustBeFirst();

error L2BlockNumberIsNeverExpectedToBeZero();

error PreviousL2BlockHashIsIncorrect();

error CannotInitializeFirstVirtualBlock();

error TimestampOfL2BlockMustBeGreaterThanOrEqualToTimestampOfCurrentBatch();

error ThereMustBeVirtualBlockCreatedAtStartOfBatch();

error CannotReuseL2BlockNumberFromPreviousBatch();

error TimestampOfSameL2BlockMustBeSame();

error PreviousHashOfSameL2BlockMustBeSame();

error CannotCreateVirtualBlocksInMiddleOfMiniblock();

error CurrentL2BlockHashIsIncorrect();

error TimestampOfNewL2BlockMustBeGreaterThanTimestampOfPreviousL2Block();

error CurrentBatchNumberMustBeGreaterThanZero();

error TimestampOfBatchMustBeGreaterThanTimestampOfPreviousBlock();

error TimestampsShouldBeIncremental();

error ProvidedBatchNumberIsNotCorrect();

error SafeERC20ApproveFromNonZeroToNonZeroAllowance();

error SafeERC20DecreasedAllowanceBelowZero();

error SafeERC20PermitDidNotSucceed();

error SafeERC20OperationDidNotSucceed();

error AddressInsufficientBalance();

error AddressUnableToSendValue();

error AddressInsufficientBalanceForCall();

error AddressCallToNonContract();

error CodeOracleCallFailed();

error ReturnedBytecodeDoesNotMatchExpectedHash();

error SecondCallShouldHaveCostLessGas();

error ThirdCallShouldHaveSameGasCostAsSecondCall();

error CallToKeccakShouldHaveSucceeded();

error KeccakReturnDataSizeShouldBe32Bytes();

error KeccakResultIsNotCorrect();

error KeccakShouldStartWorkingAgain();

error KeccakMismatchBetweenNumberOfInputsAndOutputs();

error KeccakHashWasNotCalculatedCorrectly();

error TransactionFailed();

error NotEnoughGas();

error TooMuchGas();