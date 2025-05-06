// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0x86bb51b8
error AddressHasNoCode(address);
// 0xefce78c7
error CallerMustBeBootloader();
// 0xbe4bf9e4
error CallerMustBeEvmContract();
// 0x9eedbd2b
error CallerMustBeSystemContract();
// 0x4f951510
error CompressionValueAddError(uint256 expected, uint256 actual);
// 0x1e6aff87
error CompressionValueTransformError(uint256 expected, uint256 actual);
// 0xc2ea251e
error CompressionValueSubError(uint256 expected, uint256 actual);
// 0x849acb7f
error CompressorInitialWritesProcessedNotEqual(uint256 expected, uint256 actual);
// 0x61a6a4b3
error CompressorEnumIndexNotEqual(uint256 expected, uint256 actual);
// 0x9be48d8d
error DerivedKeyNotEqualToCompressedValue(bytes32 expected, bytes32 provided);
// 0xe223db5e
error DictionaryDividedByEightNotGreaterThanEncodedDividedByTwo();
// 0x1c25715b
error EmptyBytes32();
// 0xc06d5cb2
error EncodedAndRealBytecodeChunkNotEqual(uint64 expected, uint64 provided);
// 0x2bfbfc11
error EncodedLengthNotFourTimesSmallerThanOriginal();
// 0x39bae0e6
error EVMBytecodeHash();
// 0x536a56c8
error EVMBytecodeHashUnknown();
// 0xb9e6e31f
error EVMEmulationNotSupported();
// 0xe95a1fbe
error FailedToChargeGas();
// 0x1f70c58f
error FailedToPayOperator();
// 0x9e4a3c8a
error HashIsNonZero(bytes32);
// 0x0b08d5be
error HashMismatch(bytes32 expected, bytes32 actual);
// 0x4e23d035
error IndexOutOfBounds();
// 0x122e73e9
error IndexSizeError();
// 0x03eb8b54
error InsufficientFunds(uint256 required, uint256 actual);
// 0xae962d4e
error InvalidCall();
// 0x8cbd7f8b
error InvalidCodeHash(CodeHashReason);
// 0xb4fa3fb3
error InvalidInput();
// 0x60b85677
error InvalidNonceOrderingChange();
// 0xc6b7f67d
error InvalidSig(SigField, uint256);
// 0xf4a271b5
error Keccak256InvalidReturnData();
// 0xcea34703
error MalformedBytecode(BytecodeError);
// 0xe90aded4
error NonceAlreadyUsed(address account, uint256 nonce);
// 0x45ac24a6
error NonceIncreaseError(uint256 max, uint256 proposed);
// 0x1f2f8478
error NonceNotUsed(address account, uint256 nonce);
// 0x760a1568
error NonEmptyAccount();
// 0x536ec84b
error NonEmptyMsgValue();
// 0x50df6bc3
error NotAllowedToDeployInKernelSpace();
// 0x35278d12
error Overflow();
// 0xe5ec477a
error ReconstructionMismatch(PubdataField, bytes32 expected, bytes32 actual);
// 0x3adb5f1d
error ShaInvalidReturnData();
// 0xbd8665e2
error StateDiffLengthMismatch();
// 0x71c3da01
error SystemCallFlagRequired();
// 0xe0456dfe
error TooMuchPubdata(uint256 limit, uint256 supplied);
// 0x8e4a23d6
error Unauthorized(address);
// 0x3e5efef9
error UnknownCodeHash(bytes32);
// 0x9ba6061b
error UnsupportedOperation();
// 0xff15b069
error UnsupportedPaymasterFlow();
// 0x17a84415
error UnsupportedTxType(uint256);
// 0x626ade30
error ValueMismatch(uint256 expected, uint256 actual);
// 0x4f2b5b33
error SloadContractBytecodeUnknown();
// 0x43197434
error PreviousBytecodeUnknown();

// 0x7a47c9a2
error InvalidChainId();

// 0xc84a0422
error UpgradeTransactionMustBeFirst();

// 0x543f4c07
error L2BlockNumberZero();

// 0x702a599f
error PreviousL2BlockHashIsIncorrect(bytes32 correctPrevBlockHash, bytes32 expectedPrevL2BlockHash);

// 0x2692f507
error CannotInitializeFirstVirtualBlock();

// 0x5e9ad9b0
error L2BlockAndBatchTimestampMismatch(uint128 l2BlockTimestamp, uint128 currentBatchTimestamp);

// 0x159a6f2e
error InconsistentNewBatchTimestamp(uint128 newBatchTimestamp, uint128 lastL2BlockTimestamp);

// 0xdcdfb0da
error NoVirtualBlocks();

// 0x141d6142
error CannotReuseL2BlockNumberFromPreviousBatch();

// 0xf34da52d
error IncorrectSameL2BlockTimestamp(uint128 l2BlockTimestamp, uint128 currentL2BlockTimestamp);

// 0x5822b85d
error IncorrectSameL2BlockPrevBlockHash(bytes32 expectedPrevL2BlockHash, bytes32 latestL2blockHash);

// 0x6d391091
error IncorrectVirtualBlockInsideMiniblock();

// 0xdf841e81
error IncorrectL2BlockHash(bytes32 expectedPrevL2BlockHash, bytes32 pendingL2BlockHash);

// 0x35dbda93
error NonMonotonicL2BlockTimestamp(uint128 l2BlockTimestamp, uint128 currentL2BlockTimestamp);

// 0x6ad429e8
error CurrentBatchNumberMustBeGreaterThanZero();

// 0x09c63320
error TimestampsShouldBeIncremental(uint128 newTimestamp, uint128 previousBatchTimestamp);

// 0x33cb1485
error ProvidedBatchNumberIsNotCorrect(uint128 previousBatchNumber, uint128 _expectedNewNumber);

// 0xaa957ece
error CodeOracleCallFailed();

// 0x26772295
error ReturnedBytecodeDoesNotMatchExpectedHash(bytes32 returnedBytecode, bytes32 expectedBytecodeHash);

// 0x7f08f26b
error SecondCallShouldHaveCostLessGas(uint256 secondCallCost, uint256 firstCallCost);

// 0xaa016ed2
error ThirdCallShouldHaveSameGasCostAsSecondCall(uint256 thirdCallCost, uint256 secondCallCost);

// 0xee455381
error CallToKeccakShouldHaveSucceeded();

// 0x9c9d5e18
error KeccakReturnDataSizeShouldBe32Bytes(uint256 returnDataSize);

// 0x0c69f92e
error KeccakResultIsNotCorrect(bytes32 result);

// 0x262f4984
error KeccakShouldStartWorkingAgain();

// 0x034e49a6
error KeccakMismatchBetweenNumberOfInputsAndOutputs(uint256 testInputsLength, uint256 expectedOutputsLength);

// 0x92f5b709
error KeccakHashWasNotCalculatedCorrectly(bytes32 result, bytes32 expectedOutputs);

// 0xbf961a28
error TransactionFailed();

// 0xdd629f86
error NotEnoughGas();

// 0xf0b4e88f
error TooMuchGas();

// 0x8c13f15d
error InvalidNewL2BlockNumber(uint256 l2BlockNumber);

// 0xe0a0dd23
error InvalidNonceKey(uint192 nonceKey);

enum CodeHashReason {
    NotContractOnConstructor,
    NotConstructedContract
}

enum SigField {
    Length,
    V,
    S
}

enum PubdataField {
    NumberOfLogs,
    LogsHash,
    MsgHash,
    Bytecode,
    InputDAFunctionSig,
    InputLogsHash,
    InputLogsRootHash,
    InputMsgsHash,
    InputBytecodeHash,
    Offset,
    Length
}

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd,
    DictionaryLength,
    EvmBytecodeLength,
    EvmBytecodeLengthTooBig
}
