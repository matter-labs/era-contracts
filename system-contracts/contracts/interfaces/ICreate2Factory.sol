// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {IContractDeployer} from "./IContractDeployer.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that can be used for deterministic contract deployment.
interface ICreate2Factory {
    /// @notice Function that calls the `create2` method of the `ContractDeployer` contract.
    /// @dev This function accepts the same parameters as the `create2` function of the ContractDeployer system contract,
    /// so that we could efficiently relay the calldata.
    function create2(
        bytes32, // _salt
        bytes32, // _bytecodeHash
        bytes calldata // _input
    ) external payable returns (address);

    /// @notice Function that calls the `create2Account` method of the `ContractDeployer` contract.
    /// @dev This function accepts the same parameters as the `create2Account` function of the ContractDeployer system contract,
    /// so that we could efficiently relay the calldata.
    function create2Account(
        bytes32, // _salt
        bytes32, // _bytecodeHash
        bytes calldata, // _input
        IContractDeployer.AccountAbstractionVersion // _aaVersion
    ) external payable returns (address);
}
