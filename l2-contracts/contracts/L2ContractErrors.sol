// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

error InvalidCaller(address);
error InvalidInput();
error InsufficientAllowance(uint256 providedAllowance, uint256 requiredAmount);
error FailedToTransferTokens(address tokenContract, address to, uint256 amount);
error UnsupportedPaymasterFlow();
error EmptyAddress();
error EmptyBytes32();
error AddressMismatch(address expected, address supplied);
error AssetIdMismatch(bytes32 expected, bytes32 supplied);
error AmountMustBeGreaterThanZero();
error DeployFailed();
error Unauthorized();
error NonSequentialVersion();
error Unimplemented();
error UnimplementedMessage(string);
error WithdrawFailed();
error MalformedBytecode(BytecodeError);

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd,
    DictionaryLength
}

string constant BRIDGE_MINT_NOT_IMPLEMENTED = "bridgeMint is not implemented! Use deposit/depositTo methods instead.";
