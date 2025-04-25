// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Transaction} from "../libraries/TransactionHelper.sol";

struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    /// @dev concatenation of verificationGasLimit (16 bytes) and callGasLimit (16 bytes)
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    /// @dev concatenation of maxPriorityFeePerGas (16 bytes) and maxFeePerGas (16 bytes)
    bytes32 gasFees;
    /// @dev concatenation of paymaster fields (or empty)
    bytes paymasterAndData;
    bytes signature;
}

interface IEntryPoint {
    function handleUserOps(PackedUserOperation[] calldata _ops) external;
}
