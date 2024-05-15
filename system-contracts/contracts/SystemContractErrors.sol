// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

error Unauthorized(address);
error InvalidCodeHash(CodeHashReason);
error UnsupportedTxType(uint256);
error AddressHasNoCode(address);
error EncodingLengthMismatch();
error IndexOutOfBounds();
error ValuesNotEqual(uint256 expected, uint256 actual);
error HashMismatch(bytes32 expected, uint256 actual);
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
