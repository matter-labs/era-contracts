// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice Defines what types of bytecode are allowed to be deployed on this chain
/// - `EraVm` means that only native contracts can be deployed
/// - `EraVmAndEVM` means that native contracts and EVM contracts can be deployed
enum AllowedBytecodeTypes {
    EraVm,
    EraVmAndEVM
}
