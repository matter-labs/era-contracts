// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0x1f73225f
error AddressMismatch(address expected, address supplied);
<<<<<<< HEAD:l2-contracts/contracts/L2ContractErrors.sol
error AssetIdMismatch(bytes32 expected, bytes32 supplied);
=======
// 0x5e85ae73
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe:l2-contracts/contracts/errors/L2ContractErrors.sol
error AmountMustBeGreaterThanZero();
// 0xb4f54111
error DeployFailed();
// 0x7138356f
error EmptyAddress();
// 0x1c25715b
error EmptyBytes32();
// 0x1bdfd505
error FailedToTransferTokens(address tokenContract, address to, uint256 amount);
// 0x2a1b2dd8
error InsufficientAllowance(uint256 providedAllowance, uint256 requiredAmount);
// 0xcbd9d2e0
error InvalidCaller(address);
// 0xb4fa3fb3
error InvalidInput();
// 0x0ac76f01
error NonSequentialVersion();
// 0x8e4a23d6
error Unauthorized(address);
// 0x6e128399
error Unimplemented();
// 0xa4dde386
error UnimplementedMessage(string message);
// 0xff15b069
error UnsupportedPaymasterFlow();
// 0x750b219c
error WithdrawFailed();
<<<<<<< HEAD:l2-contracts/contracts/L2ContractErrors.sol
error MalformedBytecode(BytecodeError);

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd,
    DictionaryLength
}
=======
// 0xd92e233d
error ZeroAddress();
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe:l2-contracts/contracts/errors/L2ContractErrors.sol

string constant BRIDGE_MINT_NOT_IMPLEMENTED = "bridgeMint is not implemented! Use deposit/depositTo methods instead.";
