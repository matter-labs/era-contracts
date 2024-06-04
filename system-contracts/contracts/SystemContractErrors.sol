// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

error Unauthorized(address);
error InvalidCodeHash(CodeHashReason);
error UnsupportedTxType(uint256);
error AddressHasNoCode(address);
error EncodingLengthMismatch();
error IndexOutOfBounds();
error ValuesNotEqual(uint256 expected, uint256 actual);
error HashMismatch(bytes32 expected, bytes32 actual);
error IndexSizeError();
error UnsupportedOperation();
error InvalidNonceOrderingChange();
error EmptyBytes32();
error NotAllowedToDeployInKernelSpace();
error HashIsNonZero(bytes32);
error NonEmptyAccount();
error UnknownCodeHash(bytes32);
error NonEmptyMsgValue();
error InsufficientFunds(uint256 required, uint256 actual);
error InvalidSig(SigField, uint256);
error FailedToPayOperator();
error InsufficientGas();
error MalformedBytecode(BytecodeError);
error ReconstructionMismatch(PubdataField, bytes32 expected, bytes32 actual);
error InvalidCall();
error NonceIncreaseError(uint256 max, uint256 proposed);
error ZeroNonceError();
error NonceJumpError();
error NonceAlreadyUsed(address account, uint256 nonce);
error NonceNotUsed(address account, uint256 nonce);
error TooMuchPubdata(uint256 limit, uint256 supplied);
error UpgradeMustBeFirstTxn();
error L2BlockMustBeGreaterThanZero();
error FirstL2BlockInitializationError();
error NonIncreasingTimestamp();
error EmptyVirtualBlocks();
error SystemCallFlagRequired();
error CallerMustBeSystemContract();
error CallerMustBeBootloader();
error CallerMustBeForceDeployer();
error InvalidData();
error FailedToChargeGas();
error Overflow();
error InvalidInput();
error UnsupportedPaymasterFlow();
// 0xd11fe36c
error UpgradeTxMustBeFirst();
// 0x903e89d9
error L2BlockCannotBeZero();
// 0xd4aa0d85
error L2BlockNumberAlreadyUsed();
// 0xd54b530a
error TimestampNotEqual(uint256 expected, uint256 actual);
// 0xd72810cc
error InvalidL2BlockNumber();
// 0x87cbf28a
error L2BatchCannotBeZero();

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
