// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0x8e4a23d6
error Unauthorized(address);
// 0x6a84bc39
error InvalidCodeHash(CodeHashReason);
// 0x17a84415
error UnsupportedTxType(uint256);
// 0x86bb51b8
error AddressHasNoCode(address);
// 0x608aa3da
error EncodingLengthMismatch();
// 0x4e23d035
error IndexOutOfBounds();
// 0x460b9939
error ValuesNotEqual(uint256 expected, uint256 actual);
// 0x86302004
error HashMismatch(bytes32 expected, uint256 actual);
// 0x122e73e9
error IndexSizeError();
// 0x9ba6061b
error UnsupportedOperation();
// 0x60b85677
error InvalidNonceOrderingChange();
// 0x1c25715b
error EmptyBytes32();
// 0x50df6bc3
error NotAllowedToDeployInKernelSpace();
// 0x9e4a3c8a
error HashIsNonZero(bytes32);
// 0x760a1568
error NonEmptyAccount();
// 0x3e5efef9
error UnknownCodeHash(bytes32);
// 0x536ec84b
error NonEmptyMsgValue();
// 0x03eb8b54
error InsufficientFunds(uint256 required, uint256 actual);
// 0x90f049c9
error InvalidSig(SigField, uint256);
// 0x1f70c58f
error FailedToPayOperator();
// 0x1c26714c
error InsufficientGas();
// 0x43e266b0
error MalformedBytecode(BytecodeError);
// 0x7f7b0cf7
error ReconstructionMismatch(PubdataField, bytes32 expected, bytes32 actual);
// 0xae962d4e
error InvalidCall();
// 0x45ac24a6
error NonceIncreaseError(uint256 max, uint256 proposed);
// 0x6818f3f9
error ZeroNonceError();
// 0x13595475
error NonceJumpError();
// 0xe90aded4
error NonceAlreadyUsed(address account, uint256 nonce);
// 0x1f2f8478
error NonceNotUsed(address account, uint256 nonce);
// 0xe0456dfe
error TooMuchPubdata(uint256 limit, uint256 supplied);
// 0x5708aead
error UpgradeMustBeFirstTxn();
// 0xd2906dd9
error L2BlockMustBeGreaterThanZero();
// 0x9d5da395
error FirstL2BlockInitializationError();
// 0xd018e08e
error NonIncreasingTimestamp();
// 0x92bf3cf8
error EmptyVirtualBlocks();
// 0x71c3da01
error SystemCallFlagRequired();
// 0x9eedbd2b
error CallerMustBeSystemContract();
// 0xefce78c7
error CallerMustBeBootloader();
// 0xb7549616
error CallerMustBeForceDeployer();
// 0x5cb045db
error InvalidData();
// 0xe95a1fbe
error FailedToChargeGas();
// 0x35278d12
error Overflow();
// 0xb4fa3fb3
error InvalidInput();
// 0xff15b069
error UnsupportedPaymasterFlow();
// 0x2bfbfc11
error EncodedLengthNotFourTimesSmallerThanOriginal();
// 0xdb02de6c
error DictionaryLengthNotFourTimesSmallerThanEncoded();
// 0xc06d5cb2
error EncodedAndRealBytecodeChunkNotEqual(uint64 expected, uint64 provided);
// 0x9be48d8d
error DerivedKeyNotEqualToCompressedValue(bytes32 expected, bytes32 provided);
// 0xf4a271b5
error Keccak256InvalidReturnData();
// 0x3adb5f1d
error ShaInvalidReturnData();

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
    StateDiffCompressionVersion,
    ExtraData
}

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd,
    DictionaryLength
}
