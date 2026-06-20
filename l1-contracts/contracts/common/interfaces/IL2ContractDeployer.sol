// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice Defines what types of bytecode are allowed to be deployed on this chain
/// - `EraVm` means that only native contracts can be deployed
/// - `EraVmAndEVM` means that native contracts and EVM contracts can be deployed
enum AllowedBytecodeTypes {
    EraVm,
    EraVmAndEVM
}

/**
 * @author Matter Labs
 * @notice System smart contract that is responsible for deploying other smart contracts on a ZK chain.
 */
interface IL2ContractDeployer {
    /// @notice A struct that describes a forced deployment on an address.
    /// @param bytecodeHash The bytecode hash to put on an address.
    /// @param newAddress The address on which to deploy the bytecodehash to.
    /// @param callConstructor Whether to run the constructor on the force deployment.
    /// @param value The `msg.value` with which to initialize a contract.
    /// @param input The constructor calldata.
    struct ForceDeployment {
        bytes32 bytecodeHash;
        address newAddress;
        bool callConstructor;
        uint256 value;
        bytes input;
    }

    /// @notice Returns what types of bytecode are allowed to be deployed on this chain
    function allowedBytecodeTypesToDeploy() external view returns (AllowedBytecodeTypes mode);

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external;

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE2` opcode.
    /// @param _salt The create2 salt.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata.
    function create2(bytes32 _salt, bytes32 _bytecodeHash, bytes calldata _input) external;

    /// @notice Changes what types of bytecodes are allowed to be deployed on the chain.
    /// @param newAllowedBytecodeTypes The new allowed bytecode types mode.
    function setAllowedBytecodeTypesToDeploy(AllowedBytecodeTypes newAllowedBytecodeTypes) external;
}
