// SPDX-License-Identifier: MIT
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

struct AdditionalForceDeploymentsData {
    bytes32 baseTokenAssetId;
    address l2LegacySharedBridge;
    address l2Weth;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2GenesisUpgrade {
    event UpgradeComplete(uint256 _chainId);

    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable;
}
