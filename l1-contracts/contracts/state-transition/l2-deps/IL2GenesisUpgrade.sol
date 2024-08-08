// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice A struct that describes a forced deployment on an address
struct ForceDeployment {
    // The bytecode hash to put on an address
    bytes32 bytecodeHash;
    // The address on which to deploy the bytecodehash to
    address newAddress;
    // Whether to run the constructor on the force deployment
    bool callConstructor;
    // The value with which to initialize a contract
    uint256 value;
    // The constructor calldata
    bytes input;
}

interface IL2GenesisUpgrade {
    function genesisUpgrade(uint256 _chainId, bytes calldata _forceDeploymentsData) external payable;
}
