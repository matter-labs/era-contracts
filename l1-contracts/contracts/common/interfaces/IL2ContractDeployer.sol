// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/**
 * @author Matter Labs
 * @notice System smart contract that is responsible for deploying other smart contracts on a zkSync hyperchain.
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

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external;

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE2` opcode.
    /// @param _salt The create2 salt.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata.
    function create2(bytes32 _salt, bytes32 _bytecodeHash, bytes calldata _input) external;
}
